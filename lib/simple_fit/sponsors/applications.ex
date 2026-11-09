defmodule SimpleFit.Sponsors.Applications do
  @moduledoc """
  The applicant's sponsor application (SF-113, ADR 0031). Part of
  `SimpleFit.Sponsors`; every function acts on the authenticated user's own
  application, found by their user id - never an id, email or owner from the
  request - so another user's application can't even be named.

  * **Saving** (`save/3`): the first save with at least one answer creates the
    draft (`client_request_id` makes it idempotent); later saves name
    `expected_revision` (stale: `{:revision_conflict, current}`). Only the
    supplied answers change, each validated now; an invalid save changes nothing.
    Answers are editable only in `draft` and `changes_requested`. A user with a
    rejected or withdrawn application can't start another yet: reapplication is
    undecided (D-SA03).
  * **Submitting** (`submit/3`): a separate operation, in one transaction under
    the application's row lock - revision, idempotency key, the published
    declaration, completeness, an immutable snapshot, the status change and the
    history event. A repeat with the same key answers the same and changes nothing.
  * **Nothing is granted.** No status creates an organization, membership,
    capability, agreement, payment or verification. Review (claim, request
    changes, approve, reject) belongs to a later task, through the SF-111 action
    framework; applicants can't set those states.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Legal.Registry
  alias SimpleFit.{RateLimit, Repo}

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationEvent,
    ApplicationPolicy,
    ApplicationSubmission,
    Organization
  }

  # Writes carrying answers (contact details, goals) are never logged, not even the
  # SQL debug log in development (CLAUDE.md rule 16).
  @unlogged [log: false]

  @type ctx :: %{optional(:request_id) => String.t() | nil}
  @type view :: %{
          application: Application.t(),
          submissions: [ApplicationSubmission.t()],
          missing: [atom()],
          declaration: map(),
          sponsor_id: Ecto.UUID.t() | nil
        }

  ## Reading

  @doc """
  The viewer's current application (draft, submitted, under review, changes
  requested), otherwise their latest one, with what it still needs. `:not_found`
  when they have none.
  """
  @spec get(User.t()) :: {:ok, view()} | {:error, :not_found}
  def get(%User{} = user) do
    case latest(user.id) do
      nil -> {:error, :not_found}
      application -> {:ok, view(application)}
    end
  end

  @doc "One of the viewer's own submissions: exactly what was sent."
  @spec get_submission(User.t(), term()) ::
          {:ok, ApplicationSubmission.t()} | {:error, :not_found}
  def get_submission(%User{id: user_id}, submission_id) do
    with {:ok, id} <- Ecto.UUID.cast(submission_id),
         %ApplicationSubmission{} = submission <-
           Repo.one(
             from(s in ApplicationSubmission,
               join: a in Application,
               on: a.id == s.application_id,
               where: s.id == ^id and a.applicant_user_id == ^user_id
             )
           ) do
      {:ok, submission}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The entry-resolution facts (SF-45): the viewer's current application, else their
  latest, as `{status, id}`, or `nil`. Read-only.
  """
  @spec entry_state(User.t()) :: {Application.status(), Ecto.UUID.t()} | nil
  def entry_state(%User{id: user_id}) do
    case latest(user_id) do
      nil -> nil
      %Application{status: status, id: id} -> {status, id}
    end
  end

  @doc "The validation policy and what submitting needs now (for the forms)."
  @spec policy() :: map()
  def policy do
    %{
      version: ApplicationPolicy.version(),
      steps: ApplicationPolicy.steps(),
      required: ApplicationPolicy.required(),
      industries: ApplicationPolicy.industries(),
      interests: ApplicationPolicy.interests(),
      scopes: ApplicationPolicy.scopes(),
      budget_bands: ApplicationPolicy.budget_bands(),
      uploads: ApplicationPolicy.uploads(),
      declaration: declaration()
    }
  end

  defp latest(user_id) do
    current = Application.current_statuses()

    Repo.one(
      from(a in Application,
        where: a.applicant_user_id == ^user_id,
        order_by: [desc: a.status in ^current, desc: a.inserted_at, desc: a.id],
        limit: 1
      )
    )
  end

  defp view(%Application{} = application) do
    %{
      application: application,
      submissions:
        Repo.all(
          from(s in ApplicationSubmission,
            where: s.application_id == ^application.id,
            order_by: s.sequence
          )
        ),
      missing: ApplicationPolicy.missing(application),
      declaration: declaration(),
      sponsor_id: organization_id(application)
    }
  end

  # An organization exists only after an approval created it (a later task).
  defp organization_id(%Application{status: :approved, id: id}),
    do: Repo.one(from(o in Organization, where: o.source_application_id == ^id, select: o.id))

  defp organization_id(_application), do: nil

  # The declaration a submission must accept: the published version, if any.
  defp declaration do
    case Registry.published(ApplicationPolicy.declaration_document()) do
      {:ok, version} ->
        %{
          available: true,
          document_id: version.document_id,
          version: version.version,
          languages: version.languages |> Map.keys() |> Enum.sort()
        }

      :error ->
        %{
          available: false,
          document_id: ApplicationPolicy.declaration_document(),
          version: nil,
          languages: []
        }
    end
  end

  ## Saving

  @doc "Saves answers to the viewer's draft, creating it on the first meaningful save."
  @spec save(User.t(), map(), ctx()) :: {:ok, view()} | {:error, term()}
  def save(%User{} = user, params, ctx \\ %{}) when is_map(params) do
    with :ok <- registered(user),
         {:ok, request} <- cast_save(params) do
      Repo.transaction(fn -> save!(user, request, ctx) end)
      |> case do
        {:ok, application} ->
          {:ok, view(application)}

        {:error, {:insert_race, request}} ->
          resolve_race(user, request)

        {:error, reason} = error ->
          :ok = refused(user, reason, ctx, "draft_save")
          error
      end
    end
  end

  defp save!(user, request, ctx) do
    case lock_current(user.id) do
      nil -> create!(user, request, ctx)
      application -> update!(user, application, request, ctx)
    end
  end

  defp create!(user, %{answers: answers} = request, ctx) do
    client_request_id = startable!(user, request)

    changeset =
      %Application{
        applicant_user_id: user.id,
        status: :draft,
        client_request_id: client_request_id
      }
      |> ApplicationPolicy.changeset(answers)
      |> unique_constraint(:applicant_user_id, name: :sponsor_applications_one_current_index)
      |> unique_constraint([:applicant_user_id, :client_request_id],
        name: :sponsor_applications_applicant_user_id_client_request_id_index
      )

    case Repo.insert(changeset, @unlogged) do
      {:ok, application} ->
        # Counted only when a draft is really created: retries never use it up.
        :ok = limit!("sponsor_application_create", user.id, 5, 86_400)
        event!(application, "sponsor_application.created", user, ctx, to_status: "draft")
        application

      {:error, %Ecto.Changeset{errors: errors} = invalid} ->
        if Keyword.has_key?(errors, :applicant_user_id),
          do: Repo.rollback({:insert_race, request}),
          else: Repo.rollback(invalid)
    end
  end

  # A new application needs a meaningful answer, its key, no closed application
  # before it (reapplication undecided, D-SA03) and a key never used before.
  defp startable!(user, %{answers: answers} = request) do
    unless meaningful?(answers), do: Repo.rollback(nothing_to_save())
    key = request.client_request_id || Repo.rollback(required_error(:client_request_id))

    if Repo.exists?(
         from(a in Application,
           where:
             a.applicant_user_id == ^user.id and a.status not in ^Application.current_statuses()
         )
       ),
       do: Repo.rollback({:conflict, %{application: "reapplication_unavailable"}})

    # The key is taken (a concurrent identical request committed first): answer as a
    # retry would, after the lock (`resolve_race/2`).
    if Repo.exists?(
         from(a in Application,
           where: a.applicant_user_id == ^user.id and a.client_request_id == ^key
         )
       ),
       do: Repo.rollback({:insert_race, request})

    key
  end

  defp update!(user, application, request, ctx) do
    cond do
      is_nil(request.expected_revision) ->
        replay_or_stale!(application, request)

      application.status not in Application.editable_statuses() ->
        Repo.rollback(
          {:conflict, %{application: "not_editable", status: Atom.to_string(application.status)}}
        )

      application.revision != request.expected_revision ->
        Repo.rollback({:revision_conflict, %{current_revision: application.revision}})

      request.answers == %{} ->
        application

      true ->
        :ok = limit!("sponsor_application_update", user.id, 120, 3600)
        changeset = ApplicationPolicy.changeset(application, request.answers)

        cond do
          not changeset.valid? ->
            Repo.rollback(changeset)

          changeset.changes == %{} ->
            application

          true ->
            updated = Repo.update!(changeset, @unlogged)
            event!(updated, "sponsor_application.updated", user, ctx, revision: updated.revision)
            updated
        end
    end
  end

  # A create retried after its answer was lost: the same key and the same answers
  # answer with the draft; anything else is stale.
  defp replay_or_stale!(application, request) do
    same_answers =
      application
      |> ApplicationPolicy.changeset(request.answers)
      |> Map.fetch!(:changes)
      |> Kernel.==(%{})

    if request.client_request_id == application.client_request_id and same_answers,
      do: application,
      else: Repo.rollback({:revision_conflict, %{current_revision: application.revision}})
  end

  # Two first saves at once: one inserted; the other answers as a retry of it would.
  defp resolve_race(user, request) do
    Repo.transaction(fn ->
      case lock_current(user.id) do
        nil -> Repo.rollback({:conflict, %{application: "exists"}})
        application -> replay_or_stale!(application, request)
      end
    end)
    |> case do
      {:ok, application} -> {:ok, view(application)}
      error -> error
    end
  end

  defp lock_current(user_id) do
    Repo.one(
      from(a in Application,
        where: a.applicant_user_id == ^user_id and a.status in ^Application.current_statuses(),
        lock: "FOR UPDATE"
      )
    )
  end

  ## Submitting

  @doc """
  Submits the viewer's draft (or changes-requested application): `expected_revision`,
  `client_request_id`, `declaration_accepted: true`, `declaration_version` and
  `declaration_language` of the published declaration.
  """
  @spec submit(User.t(), map(), ctx()) :: {:ok, view()} | {:error, term()}
  def submit(%User{} = user, params, ctx \\ %{}) when is_map(params) do
    with :ok <- registered(user),
         {:ok, request} <- cast_submit(params) do
      Repo.transaction(fn -> submit!(user, request, ctx) end)
      |> case do
        {:ok, application} ->
          {:ok, view(application)}

        {:error, {:replayed, application}} ->
          {:ok, view(application)}

        {:error, reason} = error ->
          :ok = refused(user, reason, ctx, "submit")
          error
      end
    end
  end

  defp submit!(user, request, ctx) do
    application = lock_current(user.id) || Repo.rollback(:not_found)
    replay!(application, request)

    if application.status not in Application.editable_statuses(),
      do:
        Repo.rollback(
          {:conflict,
           %{application: "not_submittable", status: Atom.to_string(application.status)}}
        )

    if application.revision != request.expected_revision,
      do: Repo.rollback({:revision_conflict, %{current_revision: application.revision}})

    variant = declaration!(request)

    case ApplicationPolicy.missing(application) do
      [] -> :ok
      missing -> Repo.rollback(incomplete(missing))
    end

    :ok = limit!("sponsor_application_submit", user.id, 10, 86_400)
    now = DateTime.utc_now()
    snapshot = ApplicationPolicy.snapshot(application)

    submission =
      Repo.insert!(
        %ApplicationSubmission{
          application_id: application.id,
          sequence: next_sequence(application.id),
          application_revision: application.revision,
          policy_version: ApplicationPolicy.version(),
          declaration_document_id: ApplicationPolicy.declaration_document(),
          declaration_version: request.declaration_version,
          declaration_language: variant.language,
          declaration_content_sha256: variant.content_sha256,
          snapshot: snapshot,
          snapshot_sha256: :crypto.hash(:sha256, Jason.encode!(snapshot)),
          client_request_id: request.client_request_id,
          request_sha256: request.digest,
          submitted_by_user_id: user.id,
          submitted_at: now
        },
        @unlogged
      )

    updated = Repo.update!(change(application, status: :submitted, submitted_at: now))

    event!(
      updated,
      if(application.status == :changes_requested,
        do: "sponsor_application.resubmitted",
        else: "sponsor_application.submitted"
      ),
      user,
      ctx,
      from_status: Atom.to_string(application.status),
      to_status: "submitted",
      revision: updated.revision,
      submission_id: submission.id
    )

    updated
  end

  # The same key and request again: the same answer, nothing new. The key for a
  # different request: refused.
  defp replay!(application, request) do
    case Repo.one(
           from(s in ApplicationSubmission,
             where:
               s.application_id == ^application.id and
                 s.client_request_id == ^request.client_request_id
           )
         ) do
      nil ->
        :ok

      %ApplicationSubmission{request_sha256: digest} when digest == request.digest ->
        Repo.rollback({:replayed, application})

      _other ->
        Repo.rollback({:conflict, %{client_request_id: "reused"}})
    end
  end

  defp next_sequence(application_id),
    do:
      Repo.aggregate(
        from(s in ApplicationSubmission, where: s.application_id == ^application_id),
        :count
      ) +
        1

  defp declaration!(request) do
    with {:ok, published} <- Registry.published(ApplicationPolicy.declaration_document()),
         true <- published.version == request.declaration_version || {:stale, published.version},
         {:ok, variant} <- Map.fetch(published.languages, request.declaration_language) do
      variant
    else
      :error ->
        if Registry.published(ApplicationPolicy.declaration_document()) == :error,
          do: Repo.rollback({:conflict, %{declaration: "unavailable"}}),
          else: Repo.rollback(field_error(:declaration_language, "is not available", :inclusion))

      {:stale, _current} ->
        Repo.rollback({:conflict, %{declaration: "stale"}})
    end
  end

  ## Helpers

  defp registered(user) do
    if Accounts.registration_complete?(user),
      do: :ok,
      else: {:error, {:conflict, %{account_registration: "incomplete"}}}
  end

  defp cast_save(params) do
    types = %{expected_revision: :integer, client_request_id: Ecto.UUID}

    known =
      Enum.map(ApplicationPolicy.answers(), &Atom.to_string/1) ++
        ["expected_revision", "client_request_id"]

    changeset =
      {%{}, types}
      |> cast(params, Map.keys(types))
      |> validate_number(:expected_revision, greater_than_or_equal_to: 1)
      |> reject_unknown(params, known)

    if changeset.valid? do
      answers = Map.take(params, Enum.map(ApplicationPolicy.answers(), &Atom.to_string/1))

      {:ok,
       Map.put(apply_changes(changeset), :answers, answers)
       |> defaults([:expected_revision, :client_request_id])}
    else
      {:error, changeset}
    end
  end

  defp cast_submit(params) do
    types = %{
      expected_revision: :integer,
      client_request_id: Ecto.UUID,
      declaration_accepted: :boolean,
      declaration_version: :string,
      declaration_language: :string
    }

    changeset =
      {%{}, types}
      |> cast(params, Map.keys(types))
      |> validate_required(Map.keys(types))
      |> validate_number(:expected_revision, greater_than_or_equal_to: 1)
      |> validate_acceptance(:declaration_accepted)
      |> validate_length(:declaration_version, max: 100)
      |> validate_length(:declaration_language, max: 10)
      |> reject_unknown(params, Enum.map(Map.keys(types), &Atom.to_string/1))

    with {:ok, request} <- apply_action(changeset, :validate) do
      digest =
        :crypto.hash(
          :sha256,
          Jason.encode!([
            "sf113.submit.v1",
            request.expected_revision,
            request.declaration_version,
            request.declaration_language
          ])
        )

      {:ok, Map.put(request, :digest, digest)}
    end
  end

  # Blank answers alone never create an application.
  defp meaningful?(answers),
    do: Enum.any?(answers, fn {_field, value} -> value not in [nil, "", []] end)

  defp defaults(map, keys), do: Enum.reduce(keys, map, &Map.put_new(&2, &1, nil))

  defp reject_unknown(changeset, params, known) do
    params
    |> Map.keys()
    |> Enum.reject(&(&1 in known))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a field of the request", []}} | acc.errors], valid?: false}
    end)
  end

  defp nothing_to_save,
    do: field_error(:answers, "at least one answer is needed to start an application", :required)

  defp required_error(field), do: field_error(field, "can't be blank", :required)

  defp incomplete(missing) do
    Enum.reduce(missing, change({%{}, Map.new(missing, &{&1, :any})}), fn field, cs ->
      add_error(cs, field, "is required to submit", validation: :required)
    end)
  end

  defp field_error(field, message, validation),
    do: {%{}, %{field => :any}} |> change() |> add_error(field, message, validation: validation)

  defp limit!(bucket, user_id, count, period) do
    case RateLimit.hit([{bucket, :crypto.hash(:sha256, user_id), count, period}]) do
      :ok -> :ok
      {:error, limited} -> Repo.rollback(limited)
    end
  end

  defp event!(application, event, user, ctx, fields) do
    Repo.insert!(
      struct(
        ApplicationEvent,
        Map.merge(
          %{
            application_id: application.id,
            occurred_at: DateTime.utc_now(),
            event: event,
            outcome: :allowed,
            actor_user_id: user.id,
            request_id: request_id(ctx)
          },
          Map.new(fields)
        )
      )
    )
  end

  # Refused attempts on an existing application are history too (codes only).
  defp refused(user, reason, ctx, attempt) do
    code = refusal_code(reason)

    :telemetry.execute([:simple_fit, :sponsor_application, :refused], %{count: 1}, %{
      attempt: attempt,
      reason: code
    })

    with true <-
           code in ~w(revision_stale submission_incomplete declaration_unavailable declaration_stale),
         %Application{} = application <- latest(user.id) do
      _ =
        Repo.insert!(%ApplicationEvent{
          application_id: application.id,
          occurred_at: DateTime.utc_now(),
          event: "sponsor_application.#{attempt}_refused",
          outcome: :refused,
          actor_user_id: user.id,
          revision: application.revision,
          reason_code: code,
          request_id: request_id(ctx)
        })
    end

    :ok
  end

  defp refusal_code({:revision_conflict, _}), do: "revision_stale"
  defp refusal_code({:conflict, %{declaration: "unavailable"}}), do: "declaration_unavailable"
  defp refusal_code({:conflict, %{declaration: "stale"}}), do: "declaration_stale"
  defp refusal_code({:conflict, _}), do: "conflict"

  defp refusal_code(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {_f, {msg, _}} -> msg == "is required to submit" end),
      do: "submission_incomplete",
      else: "invalid"
  end

  defp refusal_code({:rate_limited, _}), do: "rate_limited"
  defp refusal_code(_other), do: "other"

  defp request_id(ctx) do
    case Map.get(ctx, :request_id) do
      id when is_binary(id) and byte_size(id) <= 200 -> id
      _ -> nil
    end
  end
end
