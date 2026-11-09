defmodule SimpleFit.Sponsors.Review do
  @moduledoc """
  What an operator sees of a sponsor application, and the domain changes of review
  (SF-114, ADR 0032). Operators reach this only through `SimpleFit.Operators`
  (permission, key check, audit): the projection `sponsors.applications.read` and
  the declared actions in `SimpleFit.Sponsors.ReviewActions` (claim, request
  changes). **No approval or rejection exists here.** Drafts are invisible to
  operators.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Email.Templates
  alias SimpleFit.Repo

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationChangeRequest,
    ApplicationEvent,
    ApplicationNotifications,
    ApplicationPolicy,
    Applications,
    ApplicationSubmission,
    Evidence
  }

  @reasons ~w(missing_information unclear_answers contact_details company_details other)

  @doc "Reason codes of a change request."
  @spec change_reasons() :: [String.t()]
  def change_reasons, do: @reasons

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
      latest_submission:
        Repo.one(
          from(s in ApplicationSubmission,
            where: s.application_id == ^application.id,
            order_by: [desc: s.sequence],
            limit: 1
          )
        ),
      change_request: Applications.open_change_request(application.id),
      evidence: Enum.filter(Evidence.live(application.id), & &1.submission_id)
    }
  end

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

  defp event!(application, event, operator, from, to) do
    Repo.insert!(%ApplicationEvent{
      application_id: application.id,
      occurred_at: DateTime.utc_now(),
      event: event,
      outcome: :allowed,
      actor_user_id: operator.user_id,
      from_status: Atom.to_string(from),
      to_status: Atom.to_string(to),
      revision: application.revision
    })
  end
end
