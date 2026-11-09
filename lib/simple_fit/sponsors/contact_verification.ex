defmodule SimpleFit.Sponsors.ContactVerification do
  @moduledoc """
  Verification of a sponsor application's contact email (SF-114, ADR 0032). Part
  of `SimpleFit.Sponsors`; acts only on the viewer's own current application.

  * `request/2` sends a 6-digit code to the application's current contact email.
    Only a keyed verifier of the code and a keyed digest of the address are stored
    (`SimpleFit.Sponsors.Secrets`); the code lives 15 minutes, allows five
    attempts, and a new request supersedes the previous code.
  * `confirm/3` checks the code for this application only. It's refused when the
    contact email changed since the code was sent (the code was for the old
    address), expired, used up or superseded. Success records the verified address
    digest on the application: the contact counts as verified only while the
    contact email stays that address.

  Verification proves someone controls that mailbox. It gives that person no
  account, membership, workspace or permission. Throttled per user and per
  application; answers never reveal whether an address belongs to an account.
  Needs sending enabled (`application_emails`); otherwise unavailable.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.Email.Templates
  alias SimpleFit.{RateLimit, Repo}

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationContactCode,
    ApplicationNotifications,
    Applications,
    Secrets
  }

  @unlogged [log: false]
  @ttl 15 * 60
  @max_attempts 5

  @doc "Sends a code to the contact email of the viewer's editable application."
  @spec request(User.t(), map()) :: {:ok, map()} | {:error, term()}
  def request(%User{} = user, ctx \\ %{}) do
    with :ok <- available(),
         :ok <- limit("sponsor_contact_code_user", user.id, 5, 3600) do
      Repo.transaction(fn ->
        application = editable!(user)

        email =
          application.contact_email || Repo.rollback({:conflict, %{contact_email: "missing"}})

        :ok = limit!("sponsor_contact_code_application", application.id, 3, 3600)

        supersede!(application.id)
        now = DateTime.utc_now()
        code = Secrets.new_code()
        id = Ecto.UUID.generate()

        Repo.insert!(
          %ApplicationContactCode{
            id: id,
            application_id: application.id,
            email_digest: Secrets.email_digest(email),
            code_verifier: Secrets.code_verifier(id, code),
            expires_at: DateTime.add(now, @ttl),
            inserted_at: now
          },
          @unlogged
        )

        _notification =
          ApplicationNotifications.notify!(
            application.id,
            :contact_verification_code,
            :contact,
            "contact_code:#{id}",
            {email,
             fn ->
               Templates.sponsor_contact_code(code: code, expires_in_minutes: div(@ttl, 60))
             end}
          )

        Applications.view(
          Applications.touch!(application, user, ctx, "sponsor_application.contact_code_sent")
        )
      end)
    end
  end

  @doc "Confirms the code sent to the current contact email."
  @spec confirm(User.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def confirm(%User{} = user, params, ctx \\ %{}) do
    with :ok <- available(),
         {:ok, code} <- cast_code(params),
         :ok <- limit("sponsor_contact_confirm_user", user.id, 20, 3600) do
      Repo.transaction(fn -> confirm!(user, code, ctx) end)
      |> case do
        {:ok, {:wrong, _}} -> {:error, :code_invalid}
        {:ok, {:expired, _}} -> {:error, :code_expired}
        other -> other
      end
    end
  end

  # A wrong or late code still commits its attempt (so it isn't rolled back).
  defp confirm!(user, code, ctx) do
    application = editable!(user)

    live =
      Repo.one(
        from(c in ApplicationContactCode,
          where:
            c.application_id == ^application.id and is_nil(c.consumed_at) and
              is_nil(c.superseded_at),
          lock: "FOR UPDATE"
        ),
        @unlogged
      )

    now = DateTime.utc_now()

    case check(live, application, code, now) do
      :expired ->
        {:expired, application}

      :address_changed ->
        Repo.update!(change(live, superseded_at: now), @unlogged)
        {:expired, application}

      :wrong ->
        Repo.update!(change(live, attempts: live.attempts + 1), @unlogged)
        {:wrong, application}

      :ok ->
        Repo.update!(change(live, consumed_at: now), @unlogged)

        updated =
          Repo.update!(
            change(application,
              contact_email_verified_digest: live.email_digest,
              contact_email_verified_at: now
            ),
            @unlogged
          )

        Applications.view(
          Applications.touch!(updated, user, ctx, "sponsor_application.contact_verified")
        )
    end
  end

  defp check(nil, _application, _code, _now), do: :expired

  defp check(live, application, code, now) do
    cond do
      DateTime.compare(live.expires_at, now) != :gt or live.attempts >= @max_attempts ->
        :expired

      not same_address?(live, application) ->
        :address_changed

      not Plug.Crypto.secure_compare(live.code_verifier, Secrets.code_verifier(live.id, code)) ->
        :wrong

      true ->
        :ok
    end
  end

  # The code was sent to the address that is still the contact email.
  defp same_address?(_live, %Application{contact_email: nil}), do: false

  defp same_address?(live, application),
    do:
      Plug.Crypto.secure_compare(
        live.email_digest,
        Secrets.email_digest(application.contact_email)
      )

  defp editable!(user) do
    application = Applications.lock_current(user.id) || Repo.rollback(:not_found)

    if application.status in Application.editable_statuses(),
      do: application,
      else:
        Repo.rollback(
          {:conflict, %{application: "not_editable", status: Atom.to_string(application.status)}}
        )
  end

  defp supersede!(application_id) do
    {_count, _} =
      Repo.update_all(
        from(c in ApplicationContactCode,
          where:
            c.application_id == ^application_id and is_nil(c.consumed_at) and
              is_nil(c.superseded_at)
        ),
        [set: [superseded_at: DateTime.utc_now()]],
        @unlogged
      )

    :ok
  end

  defp available,
    do: if(ApplicationNotifications.enabled?(), do: :ok, else: {:error, :service_unavailable})

  defp cast_code(params) do
    {%{}, %{code: :string}}
    |> cast(params, [:code])
    |> validate_required([:code])
    |> validate_format(:code, ~r/\A\d{6}\z/)
    |> apply_action(:validate)
    |> case do
      {:ok, %{code: code}} -> {:ok, code}
      error -> error
    end
  end

  defp limit!(bucket, id, count, period) do
    case limit(bucket, id, count, period) do
      :ok -> :ok
      {:error, limited} -> Repo.rollback(limited)
    end
  end

  defp limit(bucket, id, count, period),
    do: RateLimit.hit([{bucket, :crypto.hash(:sha256, id), count, period}])
end
