defmodule SimpleFit.Operators.Bootstrap do
  @moduledoc """
  Founder bootstrap and operator recovery by **signed ceremony** (SF-110, ADR 0028).

  A ceremony statement is a JSON file:

      {"key_id": "...", "payload": "<base64url JSON>", "signature": "<base64url Ed25519>"}

  The payload names the purpose (`bootstrap` or `recovery`), the deployment
  `environment`, the target `user_id` (and `operator_id` for recovery), the
  `permissions` (bootstrap), a unique `ceremony_id`, `issued_at` and `not_after`.
  No field is an email address, and nothing on a command line names a person.

  Trust comes only from a key in `trusted_keys/0`:

  * a **production build** reads them at compile time from reviewed configuration.
    There are none in this repository, so production bootstrap is unavailable until
    a reviewed change adds a public key (the private key never enters Git);
  * other builds read them at runtime; development uses a local key from
    `mix operators.dev_ceremony`, recorded as `local_development_ceremony`.

  `run/1` verifies the signature, the environment, the time window and the target,
  then, in one transaction under an advisory lock: refuses a ceremony id or
  statement seen before; for bootstrap, refuses if any operator has ever existed;
  creates the operator in `pending_enrollment` with explicit permission rows; and
  records the ceremony and audit events. Every refusal is audited too.

  **Limits.** Whoever holds the private key and can run code against the database
  can bootstrap; whoever can write the database directly can change any row. Those
  are infrastructure controls, not this module's.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Operators.{Audit, Ceremony, Credential, Grant, Operator, Policy, StepUp}
  alias SimpleFit.Repo

  @lock_key 110_000_001
  @prod Mix.env() == :prod

  @type key_kind :: :signed_ceremony | :local_development_ceremony
  @type error ::
          :unavailable
          | :malformed
          | :untrusted
          | :wrong_environment
          | :expired
          | :invalid
          | :replayed
          | :operator_exists
          | :user_not_eligible
          | :recovery_not_allowed

  @doc """
  The trusted public keys: `%{key_id => {public_key, kind}}`. A production build
  only has keys compiled in from reviewed configuration, all `:signed_ceremony`.
  """
  @spec trusted_keys() :: %{String.t() => {binary(), key_kind()}}
  if @prod do
    @prod_keys Application.compile_env(:simple_fit, [__MODULE__, :trusted_keys], %{})
    def trusted_keys,
      do: Map.new(@prod_keys, fn {kid, key} -> {kid, {decode_key!(key), :signed_ceremony}} end)
  else
    def trusted_keys do
      :simple_fit
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:trusted_keys, %{})
      |> Map.new(fn
        {kid, {key, kind}} -> {kid, {decode_key!(key), kind}}
        {kid, key} -> {kid, {decode_key!(key), :signed_ceremony}}
      end)
    end
  end

  @doc false
  def decode_key!(key) when byte_size(key) == 32, do: key
  def decode_key!(key) when is_binary(key), do: Base.decode64!(key)

  @doc "The deployment this build accepts statements for."
  @spec environment() :: String.t() | nil
  def environment, do: Application.get_env(:simple_fit, __MODULE__, [])[:environment]

  @doc "Reads and runs a statement file."
  @spec run_file(Path.t()) :: {:ok, Operator.t()} | {:error, error()}
  def run_file(path) do
    case File.read(path) do
      {:ok, bytes} -> run(bytes)
      {:error, _reason} -> refuse(%{}, :malformed)
    end
  end

  @doc "Verifies and consumes one statement."
  @spec run(binary()) :: {:ok, Operator.t()} | {:error, error()}
  def run(statement) when is_binary(statement) do
    with {:ok, kid, payload_bytes, signature} <- parse(statement),
         {:ok, kind} <- verify(kid, payload_bytes, signature),
         {:ok, claims} <- claims(payload_bytes),
         :ok <- check_claims(claims) do
      meta = %{kid: kid, kind: kind, sha: :crypto.hash(:sha256, payload_bytes)}
      transact(claims, meta)
    else
      {:error, reason} -> refuse(%{}, reason)
      {:error, reason, claims} -> refuse(claims, reason)
    end
  end

  defp transact(claims, meta) do
    case Repo.transaction(fn -> consume(claims, meta) end) do
      {:ok, operator} -> {:ok, operator}
      {:error, reason} -> refuse(claims, reason, meta.kind)
    end
  end

  defp parse(statement) do
    with {:ok, %{"key_id" => kid, "payload" => payload, "signature" => sig}}
         when is_binary(kid) and is_binary(payload) and is_binary(sig) <- Jason.decode(statement),
         {:ok, payload_bytes} <- Base.url_decode64(payload, padding: false),
         {:ok, signature} <- Base.url_decode64(sig, padding: false) do
      {:ok, kid, payload_bytes, signature}
    else
      _malformed -> {:error, :malformed}
    end
  end

  defp verify(kid, payload_bytes, signature) do
    keys = trusted_keys()

    cond do
      keys == %{} ->
        {:error, :unavailable}

      not Map.has_key?(keys, kid) ->
        {:error, :untrusted}

      true ->
        {public_key, kind} = Map.fetch!(keys, kid)

        if :crypto.verify(:eddsa, :none, payload_bytes, signature, [public_key, :ed25519]),
          do: {:ok, kind},
          else: {:error, :untrusted}
    end
  end

  defp claims(payload_bytes) do
    with {:ok, %{"version" => 1, "purpose" => purpose} = raw}
         when purpose in ["bootstrap", "recovery"] <-
           Jason.decode(payload_bytes),
         {:ok, user_id} <- Ecto.UUID.cast(raw["user_id"]),
         {:ok, ceremony_id} <- Ecto.UUID.cast(raw["ceremony_id"]),
         {:ok, issued_at, _} <- DateTime.from_iso8601(raw["issued_at"] || ""),
         {:ok, not_after, _} <- DateTime.from_iso8601(raw["not_after"] || ""),
         {:ok, operator_id} <- optional_uuid(raw["operator_id"]) do
      {:ok,
       %{
         purpose: String.to_existing_atom(purpose),
         environment: raw["environment"],
         user_id: user_id,
         operator_id: operator_id,
         permissions: raw["permissions"] || [],
         ceremony_id: ceremony_id,
         issued_at: issued_at,
         not_after: not_after
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: Ecto.UUID.cast(value)

  defp check_claims(claims) do
    now = DateTime.utc_now()

    [
      {environment_matches?(claims), :wrong_environment},
      {window_valid?(claims), :invalid},
      {current?(claims, now), :expired},
      {purpose_valid?(claims), :invalid}
    ]
    |> Enum.find(fn {ok, _reason} -> not ok end)
    |> case do
      nil -> :ok
      {false, reason} -> {:error, reason, claims}
    end
  end

  defp environment_matches?(claims),
    do: environment() != nil and claims.environment == environment()

  defp window_valid?(claims) do
    DateTime.compare(claims.not_after, claims.issued_at) == :gt and
      DateTime.diff(claims.not_after, claims.issued_at) <= Policy.statement_max_lifetime()
  end

  # Not yet expired, and not issued more than a minute in the future (clock skew).
  defp current?(claims, now) do
    DateTime.compare(now, claims.not_after) == :lt and DateTime.diff(claims.issued_at, now) <= 60
  end

  defp purpose_valid?(%{purpose: :bootstrap} = claims),
    do: is_nil(claims.operator_id) and valid_permissions?(claims.permissions)

  defp purpose_valid?(%{purpose: :recovery} = claims),
    do: not is_nil(claims.operator_id) and claims.permissions == []

  defp valid_permissions?(permissions) do
    is_list(permissions) and permissions != [] and permissions == Enum.uniq(permissions) and
      Enum.all?(permissions, &Policy.permission?/1)
  end

  defp consume(claims, meta) do
    _locked = Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key])
    now = DateTime.utc_now()

    if Repo.exists?(
         from(c in Ceremony,
           where: c.id == ^claims.ceremony_id or c.statement_sha256 == ^meta.sha
         )
       ) do
      Repo.rollback(:replayed)
    end

    operator =
      case claims.purpose do
        :bootstrap -> bootstrap!(claims, meta, now)
        :recovery -> recover!(claims, now)
      end

    Repo.insert!(%Ceremony{
      id: claims.ceremony_id,
      purpose: claims.purpose,
      key_id: meta.kid,
      environment: claims.environment,
      statement_sha256: meta.sha,
      target_user_id: claims.user_id,
      operator_id: operator.id,
      consumed_at: now
    })

    Audit.record!(%{
      action: "operator.#{claims.purpose}",
      outcome: :allowed,
      authority: meta.kind,
      actor_user_id: claims.user_id,
      target_type: "operator",
      target_id: operator.id,
      ceremony_id: claims.ceremony_id
    })

    operator
  end

  defp bootstrap!(claims, meta, now) do
    if Repo.exists?(Operator), do: Repo.rollback(:operator_exists)
    eligible!(claims.user_id)

    operator =
      Repo.insert!(%Operator{
        user_id: claims.user_id,
        status: :pending_enrollment,
        bootstrap: true,
        ceremony_id: claims.ceremony_id,
        enrollment_expires_at: DateTime.add(now, Policy.ceremony_enrollment_window())
      })

    Enum.each(claims.permissions, fn permission ->
      Repo.insert!(%Grant{
        operator_id: operator.id,
        permission: permission,
        ceremony_id: claims.ceremony_id,
        reason_code: "founder_bootstrap",
        operation_id: claims.ceremony_id,
        granted_at: now
      })

      Audit.record!(%{
        action: "operator.permission_granted",
        outcome: :allowed,
        authority: meta.kind,
        permission: permission,
        target_type: "operator",
        target_id: operator.id,
        ceremony_id: claims.ceremony_id
      })
    end)

    operator
  end

  # Recovery restores the last operator manager's ability to enrol keys. It refuses
  # whenever another active manager exists: that manager resets keys instead.
  defp recover!(claims, now) do
    operator =
      Repo.one(from(o in Operator, where: o.id == ^claims.operator_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:recovery_not_allowed)

    unless recoverable?(operator, claims.user_id), do: Repo.rollback(:recovery_not_allowed)

    Repo.update_all(
      from(c in Credential, where: c.operator_id == ^operator.id and is_nil(c.revoked_at)),
      set: [revoked_at: now, revoked_reason: "recovery"]
    )

    Repo.update_all(
      from(s in StepUp, where: s.operator_id == ^operator.id and is_nil(s.revoked_at)),
      set: [revoked_at: now]
    )

    operator
    |> Ecto.Changeset.change(
      status: :pending_enrollment,
      enrollment_expires_at: DateTime.add(now, Policy.ceremony_enrollment_window())
    )
    |> Repo.update!()
  end

  # The named user's own, not revoked, holding operators.manage, and no other active
  # operator holds it.
  defp recoverable?(operator, user_id) do
    operator.user_id == user_id and operator.status != :revoked and
      manages?(from(o in Operator, where: o.id == ^operator.id)) and
      not manages?(from(o in Operator, where: o.status == :active and o.id != ^operator.id))
  end

  defp manages?(operators) do
    Repo.exists?(
      from(g in Grant,
        join: o in subquery(operators),
        on: o.id == g.operator_id,
        where: g.permission == "operators.manage" and is_nil(g.revoked_at)
      )
    )
  end

  defp eligible!(user_id) do
    user = Repo.get(User, user_id) || Repo.rollback(:user_not_eligible)

    unless Accounts.registration_complete?(user) do
      Repo.rollback(:user_not_eligible)
    end
  end

  defp refuse(claims, reason, kind \\ :signed_ceremony) do
    Audit.record!(%{
      action: "operator.ceremony_refused",
      outcome: :refused,
      authority: kind,
      actor_user_id: Map.get(claims, :user_id),
      target_type: "operator",
      target_id: Map.get(claims, :operator_id),
      ceremony_id: Map.get(claims, :ceremony_id),
      reason_code: Atom.to_string(reason)
    })

    {:error, reason}
  end
end
