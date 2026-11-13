defmodule SimpleFit.Sponsors.Partnerships do
  @moduledoc """
  A sponsor organization's partnership preferences and proposals, as its members
  see and change them (SF-130, ADR 0034). Part of `SimpleFit.Sponsors`.

  **Authorization.** Every function names the organization and is authorized by the
  viewer's own **active** membership of it (`SimpleFit.Sponsors.authorize/3`, read on
  every call), exactly as the rest of the workspace: anyone else gets `:not_found`,
  so neither the organization nor its proposals are revealed. A proposal is found
  only inside its own organization: another organization's proposal id is
  `:not_found`. Every role reads (`view_partnerships`); the owner and managers write
  (`manage_partnerships`, D-SA38), only while the organization is active (suspended:
  `{:conflict, %{organization: "suspended"}}`). Writes run in one transaction that
  share-locks the organization and the membership first (`Sponsors.lock_access/3`), so
  a concurrent revocation or suspension either wins or comes after.

  **Preferences** (`get_preferences/2`, `save_preferences/4`): the interests, markets
  and goals the organization wants SimpleFit to know about now. The first save names
  `expected_revision: 0`; later ones the current revision. The application's own
  submitted answers are shown beside them, read-only, from its last submission: that
  snapshot stays the unchanged record of what the organization applied with. No
  budget is collected (D-SA39).

  **Proposals** (D-SA37): a nonbinding general inquiry (`general_inquiry`), created as
  a draft (`client_request_id` makes the create idempotent), edited with
  `expected_revision`, submitted as its own operation (idempotency key, completeness,
  immutable snapshot) and withdrawable until decided. An organization has at most
  `PartnershipPolicy.open_limit/0` open proposals. Review (claim, request changes,
  accept, decline) is an operator's, through the SF-111 framework
  (`SimpleFit.Sponsors.ProposalReviewActions`). No status creates a payment, campaign,
  placement, advertising entitlement, exposure guarantee or any access to athlete or
  gym data; `accepted` means SimpleFit will follow up, nothing more.

  **Opportunities** (`opportunities/2`): no inventory exists and none is invented
  (D-SA21): members get an explicit `unavailable` answer.

  No email is sent: no template, wording or staffed response exists (D-SA22).
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.{RateLimit, Repo, Sponsors}

  alias SimpleFit.Sponsors.{
    ApplicationSubmission,
    Organization,
    PartnershipEvent,
    PartnershipPolicy,
    PartnershipPreferences,
    Proposal,
    ProposalChangeRequest,
    ProposalSubmission
  }

  # Writes carrying answers (goals, summaries) are never logged (CLAUDE.md rule 16).
  @unlogged [log: false]
  @default_limit 50
  @max_limit 100

  @type ctx :: %{optional(:request_id) => String.t() | nil}

  ## Policy and opportunities

  @doc "The partnership validation policy, for forms."
  @spec policy() :: map()
  def policy, do: PartnershipPolicy.describe()

  @doc """
  Partnership opportunities for the organization (`view_partnerships`). No
  opportunity inventory exists and none is invented (D-SA21): always `unavailable`
  with reason `no_inventory`, and no entries.
  """
  @spec opportunities(User.t(), term()) ::
          {:ok, %{availability: :unavailable, reason: :no_inventory, sponsor_id: Ecto.UUID.t()}}
          | {:error, :not_found | :forbidden}
  def opportunities(%User{} = user, sponsor_id) do
    with {:ok, access} <- Sponsors.authorize(user, sponsor_id, :view_partnerships) do
      {:ok,
       %{
         sponsor_id: access.organization.id,
         availability: :unavailable,
         reason: :no_inventory
       }}
    end
  end

  ## Preferences

  @doc """
  The organization's partnership preferences (`view_partnerships`): the current ones
  (`nil` until first saved), the answers its application last submitted (`nil` for an
  organization not made from an application) and whether the viewer may edit.
  """
  @spec get_preferences(User.t(), term()) :: {:ok, map()} | {:error, :not_found | :forbidden}
  def get_preferences(%User{} = user, sponsor_id) do
    with {:ok, access} <- Sponsors.authorize(user, sponsor_id, :view_partnerships) do
      {:ok, preferences_view(access, current_preferences(access.organization.id))}
    end
  end

  @doc """
  Saves the organization's preferences (`manage_partnerships`, active organization):
  `expected_revision` (`0` to create them) and any of the preference fields. Only the
  sent fields change, each validated now; an invalid save changes nothing.
  """
  @spec save_preferences(User.t(), term(), map(), ctx()) :: {:ok, map()} | {:error, term()}
  def save_preferences(%User{} = user, sponsor_id, params, ctx \\ %{}) when is_map(params) do
    with {:ok, request} <- cast_preferences(params),
         {:ok, {access, preferences}} <-
           locked(user, sponsor_id, &save_preferences!(user, &1, request, ctx)) do
      {:ok, preferences_view(access, preferences)}
    end
  end

  defp save_preferences!(user, access, request, ctx) do
    org_id = access.organization.id

    current =
      Repo.one(
        from(p in PartnershipPreferences, where: p.organization_id == ^org_id, lock: "FOR UPDATE")
      )

    case {current, request.expected_revision} do
      {nil, 0} ->
        create_preferences!(user, org_id, request, ctx)

      {nil, _expected} ->
        Repo.rollback({:revision_conflict, %{current_revision: 0}})

      {%PartnershipPreferences{revision: revision} = preferences, revision} ->
        update_preferences!(user, preferences, request, ctx)

      {%PartnershipPreferences{revision: revision}, _stale} ->
        Repo.rollback({:revision_conflict, %{current_revision: revision}})
    end
  end

  defp create_preferences!(user, org_id, request, ctx) do
    :ok = limit!("sponsor_partnership_preferences", user.id, 120, 3600)

    changeset =
      %PartnershipPreferences{organization_id: org_id, updated_by_user_id: user.id}
      |> PartnershipPolicy.preferences_changeset(request.answers)
      |> unique_constraint(:organization_id)

    case Repo.insert(changeset, @unlogged) do
      {:ok, preferences} ->
        event!(org_id, nil, "partnership_preferences.created", user, ctx,
          revision: preferences.revision
        )

        preferences

      # A concurrent first save committed first: this one is stale.
      {:error, %Ecto.Changeset{errors: errors} = invalid} ->
        if Keyword.has_key?(errors, :organization_id),
          do: Repo.rollback({:revision_conflict, %{current_revision: 1}}),
          else: Repo.rollback(invalid)
    end
  end

  defp update_preferences!(user, preferences, request, ctx) do
    changeset =
      preferences
      |> PartnershipPolicy.preferences_changeset(request.answers)
      |> put_change(:updated_by_user_id, user.id)

    cond do
      not changeset.valid? ->
        Repo.rollback(changeset)

      Map.delete(changeset.changes, :updated_by_user_id) == %{} ->
        preferences

      true ->
        :ok = limit!("sponsor_partnership_preferences", user.id, 120, 3600)
        updated = Repo.update!(changeset, @unlogged)

        event!(preferences.organization_id, nil, "partnership_preferences.updated", user, ctx,
          revision: updated.revision
        )

        updated
    end
  end

  defp current_preferences(org_id),
    do: Repo.one(from(p in PartnershipPreferences, where: p.organization_id == ^org_id))

  defp preferences_view(access, preferences) do
    %{
      sponsor_id: access.organization.id,
      preferences: preferences,
      application_answers: application_answers(access.organization),
      can_edit: can_manage?(access)
    }
  end

  # What the organization's application last submitted about its interests, markets
  # and goals: read from the immutable submission, never from the application row.
  defp application_answers(%Organization{source_application_id: nil}), do: nil

  defp application_answers(%Organization{source_application_id: application_id}) do
    case Repo.one(
           from(s in ApplicationSubmission,
             where: s.application_id == ^application_id,
             order_by: [desc: s.sequence],
             limit: 1
           ),
           log: false
         ) do
      nil ->
        nil

      %ApplicationSubmission{snapshot: %{"answers" => answers}} = submission ->
        %{
          submitted_at: submission.submitted_at,
          policy_version: submission.policy_version,
          interests: answers["interests"] || [],
          market_scope: answers["market_scope"],
          market_countries: answers["market_countries"] || [],
          market_cities: answers["market_cities"] || [],
          goals: answers["goals"]
        }
    end
  end

  ## Proposals: reading

  @doc """
  The organization's proposals (`view_partnerships`), newest first, paged (`limit`
  1..100, default 50; `cursor`); `status` filters by one status.
  """
  @spec list_proposals(User.t(), term(), map()) ::
          {:ok,
           %{
             sponsor_id: Ecto.UUID.t(),
             entries: [map()],
             next_cursor: String.t() | nil,
             can_create: boolean()
           }}
          | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def list_proposals(%User{} = user, sponsor_id, params \\ %{}) do
    with {:ok, access} <- Sponsors.authorize(user, sponsor_id, :view_partnerships),
         {:ok, %{limit: limit, cursor: cursor, status: status}} <- list_params(params) do
      org_id = access.organization.id

      rows =
        from(p in Proposal,
          where: p.organization_id == ^org_id,
          order_by: [desc: p.inserted_at, desc: p.id],
          limit: ^(limit + 1)
        )
        |> filter_status(status)
        |> before_cursor(cursor)
        |> Repo.all(log: false)

      {page, rest} = Enum.split(rows, limit)
      open = open_change_requests(Enum.map(page, & &1.id))

      {:ok,
       %{
         sponsor_id: org_id,
         entries:
           Enum.map(page, &%{proposal: &1, change_request_open: MapSet.member?(open, &1.id)}),
         next_cursor: if(rest != [], do: encode_cursor(List.last(page))),
         can_create: can_manage?(access) and open_count(org_id) < PartnershipPolicy.open_limit()
       }}
    end
  end

  @doc "One proposal of the organization (`view_partnerships`), as its members see it."
  @spec get_proposal(User.t(), term(), term()) ::
          {:ok, map()} | {:error, :not_found | :forbidden}
  def get_proposal(%User{} = user, sponsor_id, proposal_id) do
    with {:ok, access} <- Sponsors.authorize(user, sponsor_id, :view_partnerships),
         %Proposal{} = proposal <- find(access.organization.id, proposal_id, false) do
      {:ok, view(access, proposal)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  ## Proposals: writing

  @doc """
  Creates a draft proposal (`manage_partnerships`): `client_request_id` and any
  answers. A repeat of the same request answers with the same draft; the key with
  other answers is `{:conflict, %{client_request_id: "reused"}}`. Refused with
  `{:conflict, %{proposals: "open_limit"}}` at `PartnershipPolicy.open_limit/0` open
  proposals.
  """
  @spec create_proposal(User.t(), term(), map(), ctx()) :: {:ok, map()} | {:error, term()}
  def create_proposal(%User{} = user, sponsor_id, params, ctx \\ %{}) when is_map(params) do
    with {:ok, request} <- cast_create(params) do
      write(user, sponsor_id, nil, ctx, "create", fn access ->
        create!(user, access, request, ctx)
      end)
    end
  end

  defp create!(user, access, request, ctx) do
    org_id = access.organization.id
    # Serializes creates per organization, so the open limit holds under concurrency.
    lock!("simplefit:sponsors:proposals:create:" <> org_id)

    case Repo.one(
           from(p in Proposal,
             where:
               p.organization_id == ^org_id and p.client_request_id == ^request.client_request_id
           ),
           log: false
         ) do
      %Proposal{request_sha256: digest} = existing when digest == request.digest ->
        existing

      %Proposal{} ->
        Repo.rollback({:conflict, %{client_request_id: "reused"}})

      nil ->
        if open_count(org_id) >= PartnershipPolicy.open_limit(),
          do: Repo.rollback({:conflict, %{proposals: "open_limit"}})

        changeset =
          PartnershipPolicy.proposal_changeset(
            %Proposal{
              organization_id: org_id,
              created_by_user_id: user.id,
              kind: :general_inquiry,
              status: :draft,
              client_request_id: request.client_request_id,
              request_sha256: request.digest
            },
            request.answers
          )

        if changeset.valid? do
          :ok = limit!("sponsor_proposal_create", user.id, 30, 86_400)
          proposal = Repo.insert!(changeset, @unlogged)

          event!(org_id, proposal.id, "partnership_proposal.created", user, ctx,
            to_status: "draft",
            revision: proposal.revision
          )

          proposal
        else
          Repo.rollback(changeset)
        end
    end
  end

  @doc """
  Saves answers to a draft or changes-requested proposal (`manage_partnerships`):
  `expected_revision` and any answers. After a change request only the answers it
  names may change.
  """
  @spec update_proposal(User.t(), term(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def update_proposal(%User{} = user, sponsor_id, proposal_id, params, ctx \\ %{})
      when is_map(params) do
    with {:ok, request} <- cast_update(params) do
      write(
        user,
        sponsor_id,
        proposal_id,
        ctx,
        "update",
        &update_proposal!(user, &1, proposal_id, request, ctx)
      )
    end
  end

  defp update_proposal!(user, access, proposal_id, request, ctx) do
    proposal = lock_proposal!(access, proposal_id)
    editable!(proposal, "not_editable")
    revision!(proposal, request.expected_revision)
    changeset = PartnershipPolicy.proposal_changeset(proposal, request.answers)
    :ok = requested_only!(proposal, changeset)

    cond do
      not changeset.valid? ->
        Repo.rollback(changeset)

      changeset.changes == %{} ->
        proposal

      true ->
        :ok = limit!("sponsor_proposal_update", user.id, 240, 3600)
        updated = Repo.update!(changeset, @unlogged)

        event!(
          proposal.organization_id,
          proposal.id,
          "partnership_proposal.updated",
          user,
          ctx,
          revision: updated.revision
        )

        updated
    end
  end

  @doc """
  Submits a draft or changes-requested proposal (`manage_partnerships`):
  `expected_revision` and `client_request_id`. One transaction under the proposal's
  lock: idempotency key (the same request answers the same; another request with the
  key: `{:conflict, %{client_request_id: "reused"}}`), status, revision, completeness
  (a changeset naming each missing answer), an immutable snapshot, `submitted` and the
  history event. A resubmission resolves the open change request.
  """
  @spec submit_proposal(User.t(), term(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def submit_proposal(%User{} = user, sponsor_id, proposal_id, params, ctx \\ %{})
      when is_map(params) do
    with {:ok, request} <- cast_keyed(params, "sf130.submit.v1") do
      write(
        user,
        sponsor_id,
        proposal_id,
        ctx,
        "submit",
        &submit_proposal!(user, &1, proposal_id, request, ctx)
      )
    end
  end

  defp submit_proposal!(user, access, proposal_id, request, ctx) do
    proposal = lock_proposal!(access, proposal_id)
    replay_submission!(proposal, request)
    editable!(proposal, "not_submittable")
    revision!(proposal, request.expected_revision)

    case PartnershipPolicy.missing(proposal) do
      [] -> :ok
      missing -> Repo.rollback(incomplete(missing))
    end

    :ok = limit!("sponsor_proposal_submit", user.id, 30, 86_400)
    submit!(user, proposal, request, ctx)
  end

  defp submit!(user, proposal, request, ctx) do
    now = DateTime.utc_now()
    snapshot = PartnershipPolicy.snapshot(proposal)

    submission =
      Repo.insert!(
        %ProposalSubmission{
          proposal_id: proposal.id,
          sequence: next_sequence(proposal.id),
          proposal_revision: proposal.revision,
          policy_version: PartnershipPolicy.version(),
          snapshot: snapshot,
          snapshot_sha256: :crypto.hash(:sha256, Jason.encode!(snapshot)),
          client_request_id: request.client_request_id,
          request_sha256: request.digest,
          submitted_by_user_id: user.id,
          submitted_at: now
        },
        @unlogged
      )

    resubmitted? = proposal.status == :changes_requested
    if resubmitted?, do: :ok = resolve_change_request!(proposal.id, submission.id, now)

    updated = Repo.update!(change(proposal, status: :submitted, submitted_at: now))

    event!(
      proposal.organization_id,
      proposal.id,
      if(resubmitted?,
        do: "partnership_proposal.resubmitted",
        else: "partnership_proposal.submitted"
      ),
      user,
      ctx,
      from_status: Atom.to_string(proposal.status),
      to_status: "submitted",
      revision: updated.revision,
      submission_id: submission.id
    )

    updated
  end

  defp resolve_change_request!(proposal_id, submission_id, now) do
    {_count, _} =
      Repo.update_all(
        from(c in ProposalChangeRequest,
          where: c.proposal_id == ^proposal_id and is_nil(c.resolved_at)
        ),
        set: [resolved_by_submission_id: submission_id, resolved_at: now]
      )

    :ok
  end

  @doc """
  Withdraws an open proposal (`manage_partnerships`): `expected_revision` and
  `client_request_id`. Final. A repeat of the same withdrawal answers with the
  withdrawn proposal and changes nothing.
  """
  @spec withdraw_proposal(User.t(), term(), term(), map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def withdraw_proposal(%User{} = user, sponsor_id, proposal_id, params, ctx \\ %{})
      when is_map(params) do
    with {:ok, request} <- cast_keyed(params, "sf130.withdraw.v1") do
      write(
        user,
        sponsor_id,
        proposal_id,
        ctx,
        "withdraw",
        &withdraw_proposal!(user, &1, proposal_id, request, ctx)
      )
    end
  end

  defp withdraw_proposal!(user, access, proposal_id, request, ctx) do
    proposal = lock_proposal!(access, proposal_id)

    cond do
      proposal.status == :withdrawn and
          proposal.withdrawal_request_id == request.client_request_id ->
        Repo.rollback({:replayed, proposal})

      proposal.status not in Proposal.open_statuses() ->
        Repo.rollback(
          {:conflict, %{proposal: "not_withdrawable", status: Atom.to_string(proposal.status)}}
        )

      true ->
        revision!(proposal, request.expected_revision)

        updated =
          Repo.update!(
            change(proposal,
              status: :withdrawn,
              withdrawn_at: DateTime.utc_now(),
              withdrawal_request_id: request.client_request_id
            )
          )

        event!(
          proposal.organization_id,
          proposal.id,
          "partnership_proposal.withdrawn",
          user,
          ctx,
          from_status: Atom.to_string(proposal.status),
          to_status: "withdrawn",
          revision: updated.revision
        )

        updated
    end
  end

  # One write: the access locks, the change, and the view; a refusal on a proposal the
  # viewer can see is recorded (codes only) after the rollback.
  defp write(user, sponsor_id, proposal_id, ctx, attempt, fun) do
    case locked(user, sponsor_id, fun) do
      {:ok, {access, proposal}} ->
        {:ok, view(access, proposal)}

      {:error, {:replayed, proposal}} ->
        reload_view(user, sponsor_id, proposal.id)

      {:error, reason} = error ->
        :ok = refused(user, sponsor_id, proposal_id, reason, ctx, attempt)
        error
    end
  end

  # One transaction that first share-locks the organization and the viewer's
  # membership (`Sponsors.lock_access/3`), then runs `fun` with the access.
  defp locked(user, sponsor_id, fun) do
    Repo.transaction(fn ->
      case Sponsors.lock_access(user, sponsor_id, :manage_partnerships) do
        {:ok, access} -> {access, fun.(access)}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A replay answers with the proposal as it is now.
  defp reload_view(user, sponsor_id, proposal_id) do
    with {:ok, access} <- Sponsors.authorize(user, sponsor_id, :view_partnerships),
         %Proposal{} = proposal <- find(access.organization.id, proposal_id, false) do
      {:ok, view(access, proposal)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp lock_proposal!(access, proposal_id),
    do: find(access.organization.id, proposal_id, true) || Repo.rollback(:not_found)

  defp find(org_id, proposal_id, lock?) do
    case Ecto.UUID.cast(proposal_id) do
      {:ok, id} ->
        query = from(p in Proposal, where: p.id == ^id and p.organization_id == ^org_id)
        query = if lock?, do: from(p in query, lock: "FOR UPDATE"), else: query
        Repo.one(query, log: false)

      :error ->
        nil
    end
  end

  defp editable!(%Proposal{status: status}, code) do
    if status not in Proposal.editable_statuses(),
      do: Repo.rollback({:conflict, %{proposal: code, status: Atom.to_string(status)}})

    :ok
  end

  defp revision!(%Proposal{revision: revision}, expected) do
    if revision != expected,
      do: Repo.rollback({:revision_conflict, %{current_revision: revision}})

    :ok
  end

  # The same key and request again: the same answer. The key for another request: refused.
  defp replay_submission!(proposal, request) do
    case Repo.one(
           from(s in ProposalSubmission,
             where:
               s.proposal_id == ^proposal.id and s.client_request_id == ^request.client_request_id
           ),
           log: false
         ) do
      nil ->
        :ok

      %ProposalSubmission{request_sha256: digest} when digest == request.digest ->
        Repo.rollback({:replayed, proposal})

      _other ->
        Repo.rollback({:conflict, %{client_request_id: "reused"}})
    end
  end

  # After a change request, only the answers it names can change.
  defp requested_only!(%Proposal{status: :changes_requested, id: id}, changeset) do
    allowed = (open_change_request(id) || %{fields: []}).fields

    case changeset.changes |> Map.keys() |> Enum.reject(&(Atom.to_string(&1) in allowed)) do
      [] ->
        :ok

      outside ->
        Repo.rollback(
          Enum.reduce(Enum.sort(outside), changeset, fn field, cs ->
            add_error(cs, field, "wasn't part of the change request", validation: :not_requested)
          end)
        )
    end
  end

  defp requested_only!(_proposal, _changeset), do: :ok

  ## Views

  defp view(access, %Proposal{} = proposal) do
    manage? = can_manage?(access)
    change_request = open_change_request(proposal.id)

    %{
      sponsor_id: access.organization.id,
      proposal: proposal,
      missing: PartnershipPolicy.missing(proposal),
      change_request: if(proposal.status == :changes_requested, do: change_request),
      submissions:
        Repo.all(
          from(s in ProposalSubmission,
            where: s.proposal_id == ^proposal.id,
            order_by: s.sequence,
            select: %{id: s.id, sequence: s.sequence, submitted_at: s.submitted_at}
          )
        ),
      history: history(proposal.id),
      created_by:
        Accounts.short_names([proposal.created_by_user_id])
        |> get_in([proposal.created_by_user_id, :short_name]),
      created_by_viewer: proposal.created_by_user_id == access.membership.user_id,
      actions: %{
        edit: manage? and proposal.status in Proposal.editable_statuses(),
        submit: manage? and proposal.status in Proposal.editable_statuses(),
        withdraw: manage? and proposal.status in Proposal.open_statuses()
      }
    }
  end

  # The status changes, oldest first; who made them is not shown to the organization.
  defp history(proposal_id),
    do:
      Repo.all(
        from(e in PartnershipEvent,
          where:
            e.proposal_id == ^proposal_id and e.outcome == :allowed and not is_nil(e.to_status),
          order_by: [asc: e.occurred_at, asc: e.id],
          select: %{
            from_status: e.from_status,
            to_status: e.to_status,
            occurred_at: e.occurred_at,
            actor_kind: e.actor_kind
          }
        )
      )

  # Writes need the role and an active organization.
  defp can_manage?(%{organization: %{status: :active}, membership: %{role: role}}),
    do: Sponsors.Policy.allowed?(role, :manage_partnerships)

  defp can_manage?(_access), do: false

  @doc false
  @spec open_change_request(Ecto.UUID.t()) :: ProposalChangeRequest.t() | nil
  def open_change_request(proposal_id),
    do:
      Repo.one(
        from(c in ProposalChangeRequest,
          where: c.proposal_id == ^proposal_id and is_nil(c.resolved_at)
        )
      )

  defp open_change_requests(ids),
    do:
      Repo.all(
        from(c in ProposalChangeRequest,
          where: c.proposal_id in ^ids and is_nil(c.resolved_at),
          select: c.proposal_id
        )
      )
      |> MapSet.new()

  defp open_count(org_id),
    do:
      Repo.aggregate(
        from(p in Proposal,
          where: p.organization_id == ^org_id and p.status in ^Proposal.open_statuses()
        ),
        :count
      )

  defp next_sequence(proposal_id),
    do:
      Repo.aggregate(from(s in ProposalSubmission, where: s.proposal_id == ^proposal_id), :count) +
        1

  ## Requests

  defp cast_preferences(params) do
    fields = Enum.map(PartnershipPolicy.preference_fields(), &Atom.to_string/1)

    changeset =
      {%{}, %{expected_revision: :integer}}
      |> cast(params, [:expected_revision])
      |> validate_required([:expected_revision])
      |> validate_number(:expected_revision, greater_than_or_equal_to: 0)
      |> reject_unknown(params, ["expected_revision" | fields])

    with {:ok, request} <- apply_action(changeset, :validate),
         do: {:ok, Map.put(request, :answers, Map.take(params, fields))}
  end

  defp cast_create(params) do
    fields = Enum.map(PartnershipPolicy.proposal_fields(), &Atom.to_string/1)

    changeset =
      {%{}, %{client_request_id: Ecto.UUID}}
      |> cast(params, [:client_request_id])
      |> validate_required([:client_request_id])
      |> reject_unknown(params, ["client_request_id" | fields])

    with {:ok, request} <- apply_action(changeset, :validate) do
      answers = Map.take(params, fields)
      canonical = answers |> Enum.sort() |> Enum.map(fn {k, v} -> [k, v] end)
      digest = :crypto.hash(:sha256, Jason.encode!(["sf130.create.v1", canonical]))
      {:ok, Map.merge(request, %{answers: answers, digest: digest})}
    end
  end

  defp cast_update(params) do
    fields = Enum.map(PartnershipPolicy.proposal_fields(), &Atom.to_string/1)

    changeset =
      {%{}, %{expected_revision: :integer}}
      |> cast(params, [:expected_revision])
      |> validate_required([:expected_revision])
      |> validate_number(:expected_revision, greater_than_or_equal_to: 1)
      |> reject_unknown(params, ["expected_revision" | fields])

    with {:ok, request} <- apply_action(changeset, :validate),
         do: {:ok, Map.put(request, :answers, Map.take(params, fields))}
  end

  defp cast_keyed(params, tag) do
    types = %{expected_revision: :integer, client_request_id: Ecto.UUID}

    changeset =
      {%{}, types}
      |> cast(params, Map.keys(types))
      |> validate_required(Map.keys(types))
      |> validate_number(:expected_revision, greater_than_or_equal_to: 1)
      |> reject_unknown(params, ["expected_revision", "client_request_id"])

    with {:ok, request} <- apply_action(changeset, :validate) do
      digest = :crypto.hash(:sha256, Jason.encode!([tag, request.expected_revision]))
      {:ok, Map.put(request, :digest, digest)}
    end
  end

  defp list_params(params) do
    types = %{limit: :integer, cursor: :string, status: :string}
    statuses = Enum.map(Proposal.statuses(), &Atom.to_string/1)

    changeset =
      {%{limit: @default_limit, cursor: nil, status: nil}, types}
      |> cast(Map.take(params, ["limit", "cursor", "status"]), Map.keys(types))
      |> validate_number(:limit, greater_than_or_equal_to: 1, less_than_or_equal_to: @max_limit)
      |> validate_inclusion(:status, statuses)

    with %Ecto.Changeset{valid?: true} <- changeset,
         {:ok, position} <- decode_cursor(get_field(changeset, :cursor)) do
      status = get_field(changeset, :status)

      {:ok,
       %{
         limit: get_field(changeset, :limit),
         cursor: position,
         status: status && String.to_existing_atom(status)
       }}
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      :error -> {:error, add_error(changeset, :cursor, "is invalid", validation: :format)}
    end
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from(p in query, where: p.status == ^status)

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, {at, id}),
    do: from(p in query, where: p.inserted_at < ^at or (p.inserted_at == ^at and p.id < ^id))

  defp encode_cursor(%Proposal{inserted_at: at, id: id}),
    do: Base.url_encode64("#{DateTime.to_unix(at, :microsecond)}|#{id}", padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [micros, id] <- String.split(decoded, "|"),
         {micros, ""} <- Integer.parse(micros),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :error
    end
  end

  defp reject_unknown(changeset, params, known) do
    params
    |> Map.keys()
    |> Enum.reject(&(&1 in known))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce(changeset, fn key, acc ->
      %{acc | errors: [{key, {"is not a field of the request", []}} | acc.errors], valid?: false}
    end)
  end

  defp incomplete(missing) do
    Enum.reduce(missing, change({%{}, Map.new(missing, &{&1, :any})}), fn field, cs ->
      add_error(cs, field, "is required to submit", validation: :required)
    end)
  end

  defp lock!(key) do
    %Postgrex.Result{} =
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])

    :ok
  end

  defp limit!(bucket, user_id, count, period) do
    case RateLimit.hit([{bucket, :crypto.hash(:sha256, user_id), count, period}]) do
      :ok -> :ok
      {:error, limited} -> Repo.rollback(limited)
    end
  end

  defp event!(org_id, proposal_id, event, user, ctx, fields) do
    Repo.insert!(
      struct(
        PartnershipEvent,
        Map.merge(
          %{
            organization_id: org_id,
            proposal_id: proposal_id,
            occurred_at: DateTime.utc_now(),
            event: event,
            outcome: :allowed,
            actor_user_id: user.id,
            actor_kind: :sponsor_member,
            request_id: request_id(ctx)
          },
          Map.new(fields)
        )
      )
    )
  end

  # Refusals of a member's write on a proposal of their organization are history too
  # (codes only). Unknown, foreign or unauthorized targets leave nothing.
  defp refused(user, sponsor_id, proposal_id, reason, ctx, attempt) do
    code = refusal_code(reason)

    :telemetry.execute([:simple_fit, :sponsor_partnership, :refused], %{count: 1}, %{
      attempt: attempt,
      reason: code
    })

    with true <- code in ~w(revision_stale conflict submission_incomplete),
         true <- is_binary(proposal_id),
         # SF-132: refusals can't fill the append-only history: at most 300 a user an hour.
         :ok <-
           RateLimit.hit([
             {"sponsor_partnership_refusal_event", :crypto.hash(:sha256, user.id), 300, 3600}
           ]),
         {:ok, access} <- Sponsors.authorize(user, sponsor_id, :view_partnerships),
         %Proposal{} = proposal <- find(access.organization.id, proposal_id, false) do
      _ =
        Repo.insert!(%PartnershipEvent{
          organization_id: proposal.organization_id,
          proposal_id: proposal.id,
          occurred_at: DateTime.utc_now(),
          event: "partnership_proposal.#{attempt}_refused",
          outcome: :refused,
          actor_user_id: user.id,
          actor_kind: :sponsor_member,
          revision: proposal.revision,
          reason_code: code,
          request_id: request_id(ctx)
        })
    end

    :ok
  end

  defp refusal_code({:revision_conflict, _}), do: "revision_stale"
  defp refusal_code({:conflict, _}), do: "conflict"

  defp refusal_code(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {_f, {msg, _}} -> msg == "is required to submit" end),
      do: "submission_incomplete",
      else: "invalid"
  end

  defp refusal_code({:rate_limited, _}), do: "rate_limited"
  defp refusal_code(:not_found), do: "not_found"
  defp refusal_code(:forbidden), do: "forbidden"
  defp refusal_code(_other), do: "other"

  defp request_id(ctx) do
    case Map.get(ctx, :request_id) do
      id when is_binary(id) and byte_size(id) <= 200 -> id
      _ -> nil
    end
  end
end
