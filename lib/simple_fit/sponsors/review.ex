defmodule SimpleFit.Sponsors.Review do
  @moduledoc """
  What an operator sees of a sponsor application, and the domain changes of review
  (SF-114, ADR 0032). Operators reach this only through `SimpleFit.Operators`
  (permission, key check, audit): the projections `sponsors.applications.read`
  (queue, detail) and `.read_files` (a document's download), and the declared
  actions in `SimpleFit.Sponsors.ReviewActions`. Drafts are invisible to operators.

  Decisions (SF-116, ADR 0033), each inside the action pipeline's transaction with
  the application locked:

  * **Approve** (`under_review -> approved`): the application is approved and, in the
    same transaction, its organization and the applicant's owner membership are
    provisioned with the application's own authority from exactly what was last
    submitted. Either all of it commits or none (D-SA10 and D-SA07, proposed). It
    grants no contract, plan, placement, entitlement, payment or public listing.
  * **Reject** (`under_review -> rejected`): terminal; nothing is created.
  * **Suspend / reinstate the organization** of an approved application: how a
    mistaken approval is undone (the lifecycle's "later events"). The application
    stays as it was decided; the organization becomes read-only for its members and
    stops being an entry destination, and can be reinstated. Nothing is deleted and no
    other organization or membership is touched. A `revoked` application state and
    closing an organization have no approved policy and don't exist here.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Email.Templates
  alias SimpleFit.Repo

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationChangeRequest,
    ApplicationEvent,
    ApplicationEvidence,
    ApplicationNotifications,
    ApplicationPolicy,
    Applications,
    ApplicationSubmission,
    Evidence,
    Membership,
    Organization,
    Provisioning
  }

  @reasons ~w(missing_information unclear_answers contact_details company_details other)
  # SF-116's proposed defaults; never shown to the applicant (no approved wording).
  @approve_reasons ~w(review_complete)
  @reject_reasons ~w(not_a_business outside_supported_categories insufficient_information
                     duplicate_application other)
  @restrict_reasons ~w(approval_mistaken policy_concern under_investigation other)
  @reinstate_reasons ~w(concern_resolved approval_confirmed other)

  @doc "Reason codes of a change request."
  @spec change_reasons() :: [String.t()]
  def change_reasons, do: @reasons

  @doc "Reason codes of an approval, a rejection, a suspension and a reinstatement."
  @spec decision_reasons(:approve | :reject | :suspend | :reinstate) :: [String.t()]
  def decision_reasons(:approve), do: @approve_reasons
  def decision_reasons(:reject), do: @reject_reasons
  def decision_reasons(:suspend), do: @restrict_reasons
  def decision_reasons(:reinstate), do: @reinstate_reasons

  @doc "A submitted (or later) application, or `nil` (unknown or still a draft)."
  @spec fetch(Ecto.UUID.t()) :: Application.t() | nil
  def fetch(id),
    do: Repo.one(from(a in Application, where: a.id == ^id and a.status != :draft))

  @doc false
  @spec lock!(Ecto.UUID.t()) :: Application.t() | nil
  def lock!(id),
    do:
      Repo.one(
        from(a in Application, where: a.id == ^id and a.status != :draft, lock: "FOR UPDATE")
      )

  @doc """
  The operator's view: status, the latest submission (exactly what was sent), the
  open change request and the submitted documents' metadata (no keys, no files).
  """
  @spec view(Application.t()) :: map()
  def view(%Application{} = application) do
    %{
      application: application,
      latest_submission: latest_submission(application.id),
      change_request: Applications.open_change_request(application.id),
      evidence: Enum.filter(Evidence.live(application.id), & &1.submission_id),
      organization: organization_of(application.id),
      history:
        Repo.all(
          from(e in ApplicationEvent,
            where:
              e.application_id == ^application.id and e.outcome == :allowed and
                not is_nil(e.to_status),
            order_by: [asc: e.occurred_at, asc: e.id]
          )
        )
    }
  end

  @queue_statuses ~w(submitted under_review changes_requested approved rejected withdrawn)a

  @doc "The statuses a review queue can filter on (never `draft`)."
  @spec queue_statuses() :: [atom()]
  def queue_statuses, do: @queue_statuses

  @doc """
  One page of the review queue, oldest submission first (ties by id), after
  `position` (`{submitted_at, id}`). `filters`: `:status` (one of
  `queue_statuses/0`), `:submitted_after`, `:submitted_before`. Each row has the
  application, what its latest submission says about the company (never the
  contact), the number of submissions and submitted documents, and whether a change
  request is open. Returns `{rows, next_position | nil}`.
  """
  @spec queue(map(), pos_integer(), {DateTime.t(), Ecto.UUID.t()} | nil) ::
          {[map()], {DateTime.t(), Ecto.UUID.t()} | nil}
  def queue(filters, limit, position) do
    query =
      from(a in Application, where: a.status != :draft and not is_nil(a.submitted_at))
      |> queue_filter(filters)
      |> after_queue_position(position)

    rows =
      Repo.all(
        from(a in query, order_by: [asc: a.submitted_at, asc: a.id], limit: ^(limit + 1)),
        log: false
      )

    {page, more} = Enum.split(rows, limit)
    ids = Enum.map(page, & &1.id)
    summaries = queue_summaries(ids)

    next =
      case {page, more} do
        {_, []} -> nil
        {page, _} -> {List.last(page).submitted_at, List.last(page).id}
      end

    {Enum.map(page, &Map.merge(%{application: &1}, Map.fetch!(summaries, &1.id))), next}
  end

  defp queue_filter(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, q -> from(a in q, where: a.status == ^status)
      {:submitted_after, at}, q -> from(a in q, where: a.submitted_at > ^at)
      {:submitted_before, at}, q -> from(a in q, where: a.submitted_at < ^at)
      _other, q -> q
    end)
  end

  defp after_queue_position(query, nil), do: query

  defp after_queue_position(query, {at, id}),
    do: from(a in query, where: a.submitted_at > ^at or (a.submitted_at == ^at and a.id > ^id))

  defp queue_summaries(ids) do
    latest =
      Repo.all(
        from(s in ApplicationSubmission,
          where: s.application_id in ^ids,
          distinct: s.application_id,
          order_by: [asc: s.application_id, desc: s.sequence],
          select: {s.application_id, s.snapshot, s.sequence}
        ),
        log: false
      )
      |> Map.new(fn {id, snapshot, sequence} -> {id, {snapshot["answers"], sequence}} end)

    documents =
      Repo.all(
        from(e in ApplicationEvidence,
          where: e.application_id in ^ids and not is_nil(e.submission_id),
          group_by: e.application_id,
          select: {e.application_id, count(e.id)}
        ),
        log: false
      )
      |> Map.new()

    open =
      Repo.all(
        from(c in ApplicationChangeRequest,
          where: c.application_id in ^ids and is_nil(c.resolved_at),
          select: c.application_id
        ),
        log: false
      )
      |> MapSet.new()

    Map.new(ids, fn id ->
      {answers, sequence} = Map.get(latest, id, {%{}, 0})

      {id,
       %{
         company_name: answers["company_name"],
         country_code: answers["country_code"],
         industry: answers["industry"],
         submissions: sequence,
         submitted_documents: Map.get(documents, id, 0),
         change_request_open: MapSet.member?(open, id)
       }}
    end)
  end

  @doc """
  A submitted document of a (non-draft) application, uploaded and part of a
  submission, or `nil`. Nothing else is ever downloadable by an operator.
  """
  @spec submitted_document(Application.t(), term()) ::
          ApplicationEvidence.t() | nil
  def submitted_document(%Application{id: application_id}, evidence_id) do
    case Ecto.UUID.cast(evidence_id) do
      {:ok, id} ->
        Repo.one(
          from(e in ApplicationEvidence,
            where:
              e.id == ^id and e.application_id == ^application_id and e.status == :uploaded and
                not is_nil(e.submission_id)
          )
        )

      :error ->
        nil
    end
  end

  @doc """
  Whether `user_id` holds a non-revoked membership (any role) in the organization an
  application's approval provisioned.
  """
  @spec member_of_organization?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def member_of_organization?(application_id, user_id),
    do:
      Repo.exists?(
        from(m in Membership,
          join: o in Organization,
          on: o.id == m.organization_id,
          where:
            o.source_application_id == ^application_id and m.user_id == ^user_id and
              m.status != :revoked
        )
      )

  @doc "The organization an application's approval provisioned, or `nil`."
  @spec organization_of(Ecto.UUID.t()) :: Organization.t() | nil
  def organization_of(application_id),
    do: Repo.one(from(o in Organization, where: o.source_application_id == ^application_id))

  @doc false
  # Claim: submitted -> under_review.
  @spec claim!(Application.t(), struct(), map()) :: Application.t()
  def claim!(application, operator, _attrs) do
    updated = Repo.update!(change(application, status: :under_review))
    event!(updated, "sponsor_application.claimed", operator, application.status, :under_review)
    updated
  end

  @doc false
  # Request changes: under_review -> changes_requested, the request, the applicant's email.
  @spec request_changes!(Application.t(), struct(), map(), DateTime.t()) :: Application.t()
  def request_changes!(application, operator, attrs, now) do
    request =
      Repo.insert!(%ApplicationChangeRequest{
        application_id: application.id,
        requested_by_operator_id: operator.id,
        reason_code: attrs.reason_code,
        fields: attrs.fields,
        message: attrs.message,
        application_revision: application.revision,
        requested_at: now
      })

    updated = Repo.update!(change(application, status: :changes_requested))

    event!(
      updated,
      "sponsor_application.changes_requested",
      operator,
      application.status,
      :changes_requested
    )

    applicant = Repo.get!(SimpleFit.Accounts.User, application.applicant_user_id)

    _notification =
      ApplicationNotifications.notify!(
        application.id,
        :changes_requested,
        :applicant,
        "changes_requested:#{request.id}",
        {Applications.applicant_address(applicant),
         fn ->
           Templates.sponsor_changes_requested(
             company_name: application.company_name,
             message: attrs.message
           )
         end}
      )

    updated
  end

  @doc false
  # Approve: under_review -> approved, with the organization and the owner membership
  # in the same transaction; then the applicant's email intent.
  @spec approve!(Application.t(), struct(), map(), DateTime.t(), map()) :: Application.t()
  def approve!(application, operator, attrs, now, ctx) do
    submission = latest_submission(application.id)
    updated = Repo.update!(change(application, status: :approved, decided_at: now))

    event!(updated, "sponsor_application.approved", operator, application.status, :approved,
      reason_code: attrs.reason_code,
      submission_id: submission.id
    )

    answers = submission.snapshot["answers"]

    with {:ok, authority} <- Provisioning.application_authority(application.id),
         {:ok, _provisioned} <-
           Provisioning.provision_organization(
             authority,
             organization_attrs(application, answers),
             ctx
           ) do
      notify_decision!(application, :application_approved, "approved:#{application.id}", fn ->
        Templates.sponsor_application_approved(company_name: answers["company_name"])
      end)

      updated
    else
      # Not provisioned: nothing of the approval may commit.
      {:error, reason} -> Repo.rollback(provisioning_refusal(reason))
    end
  end

  @doc false
  # Reject: under_review -> rejected. Terminal; nothing is created.
  @spec reject!(Application.t(), struct(), map(), DateTime.t()) :: Application.t()
  def reject!(application, operator, attrs, now) do
    updated = Repo.update!(change(application, status: :rejected, decided_at: now))

    event!(updated, "sponsor_application.rejected", operator, application.status, :rejected,
      reason_code: attrs.reason_code
    )

    notify_decision!(application, :application_rejected, "rejected:#{application.id}", fn ->
      Templates.sponsor_application_rejected(company_name: application.company_name)
    end)

    updated
  end

  @doc false
  # Suspends (`:suspended`) or reinstates (`:active`) the organization of an approved
  # application, as the operator, with the reason. Lock order: application, then
  # organization (taken by `Provisioning`).
  @spec restrict!(Application.t(), %{user_id: Ecto.UUID.t()}, map(), :suspended | :active, %{
          optional(:request_id) => String.t() | nil
        }) :: Application.t()
  def restrict!(application, operator, attrs, to, ctx) do
    organization =
      organization_of(application.id) || Repo.rollback({:conflict, %{organization: "none"}})

    {:ok, authority} = Provisioning.operator_authority(operator)

    result =
      case to do
        :suspended ->
          Provisioning.suspend_organization(authority, organization.id, attrs.reason_code, ctx)

        :active ->
          Provisioning.reinstate_organization(authority, organization.id, attrs.reason_code, ctx)
      end

    case result do
      {:ok, _organization} ->
        event!(application, "sponsor_application.organization_#{to}", operator, nil, nil,
          reason_code: attrs.reason_code
        )

        application

      {:error, reason} ->
        Repo.rollback(provisioning_refusal(reason))
    end
  end

  @doc "The latest submission of an application (what a reviewer decides on)."
  @spec latest_submission(Ecto.UUID.t()) :: ApplicationSubmission.t() | nil
  def latest_submission(application_id),
    do:
      Repo.one(
        from(s in ApplicationSubmission,
          where: s.application_id == ^application_id,
          order_by: [desc: s.sequence],
          limit: 1
        )
      )

  # The organization exactly as submitted: the company name is the legal name (SP1
  # collects one name) and, within the 120 characters a display name allows, the
  # display name; the applicant is the owner; the submitted contact is the primary
  # contact. The application id is the provisioning key, so a repeat can't make another.
  defp organization_attrs(application, answers) do
    %{
      provisioning_key: application.id,
      legal_name: answers["company_name"],
      display_name: String.slice(String.trim(answers["company_name"] || ""), 0, 120),
      country_code: answers["country_code"],
      website: answers["website"],
      owner_user_id: application.applicant_user_id,
      contacts: [
        %{
          kind: "primary",
          full_name: answers["contact_full_name"],
          job_title: answers["contact_position"],
          email: answers["contact_email"],
          phone: answers["contact_phone"]
        }
      ]
    }
  end

  defp provisioning_refusal({:conflict, details}), do: {:conflict, details}
  defp provisioning_refusal(:unavailable), do: {:conflict, %{organization: "exists"}}
  defp provisioning_refusal(:not_found), do: {:conflict, %{organization: "none"}}
  defp provisioning_refusal(%Ecto.Changeset{}), do: {:conflict, %{organization: "invalid"}}

  defp notify_decision!(application, kind, dedupe_key, render) do
    applicant = Repo.get!(SimpleFit.Accounts.User, application.applicant_user_id)

    _notification =
      ApplicationNotifications.notify!(
        application.id,
        kind,
        :applicant,
        dedupe_key,
        {Applications.applicant_address(applicant), render}
      )

    :ok
  end

  @doc false
  # The change request's own input: answers to revisit and a plain-text message.
  @spec validate_change_request(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_change_request(changeset) do
    answers = Enum.map(ApplicationPolicy.answers(), &Atom.to_string/1)

    changeset
    |> update_change(:message, &String.trim/1)
    |> validate_length(:message, min: 1, max: 2000)
    |> validate_length(:fields, min: 1, max: length(answers))
    |> validate_subset(:fields, answers)
    |> validate_change(:fields, fn :fields, fields ->
      if fields == Enum.uniq(fields),
        do: [],
        else: [fields: {"has duplicates", validation: :unique}]
    end)
  end

  defp event!(application, event, operator, from, to, fields \\ []) do
    Repo.insert!(
      struct(
        ApplicationEvent,
        Keyword.merge(
          [
            application_id: application.id,
            occurred_at: DateTime.utc_now(),
            event: event,
            outcome: :allowed,
            actor_user_id: operator.user_id,
            from_status: from && Atom.to_string(from),
            to_status: to && Atom.to_string(to),
            revision: application.revision
          ],
          fields
        )
      )
    )
  end
end
