defmodule SimpleFit.SponsorApplicationReviewTest do
  @moduledoc """
  SF-114 in the SQL sandbox: operator review of sponsor applications through the
  SF-111 framework (audited read, claim, request changes), and what the applicant
  can do after a change request. No approval or rejection exists.
  """

  use SimpleFit.DataCase, async: false
  use Oban.Testing, repo: SimpleFit.Repo

  import SimpleFit.OperatorHelpers
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1, email_user!: 1]

  alias SimpleFit.Operators
  alias SimpleFit.Operators.{AuditEvent, Policy, StepUp}

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationChangeRequest,
    ApplicationNotification,
    Applications,
    Membership,
    Organization
  }

  @review ~w(sponsors.applications.read sponsors.applications.claim sponsors.applications.request_changes)

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    reviewer = founder!(@review ++ ["operators.read", "operators.manage"])
    applicant = email_user!("applicant-#{System.unique_integer([:positive])}@example.com")
    app = submitted!(applicant, draft!(applicant))
    %{r: reviewer, applicant: applicant, app: app}
  end

  defp founder!(permissions) do
    user = registered!("reviewer")
    session = live_session!(user)
    op = bootstrap!(user, permissions)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

  # Another operator, provisioned by the founder with `permissions`.
  defp reviewer!(founder, prefix, permissions) do
    user = registered!(prefix)
    session = live_session!(user)

    {:ok, %{operator: op}} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op(), %{"user_id" => user.id, "permissions" => permissions})
      )

    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: Repo.reload!(op), key: step_up!(user, session, k)}
  end

  defp exec(r, action, app, params \\ %{}) do
    Operators.execute(
      action,
      r.user,
      r.session,
      app.id,
      Map.merge(
        %{
          "reason_code" => default_reason(action),
          "expected_revision" => Repo.reload!(app).revision,
          "operation_id" => Ecto.UUID.generate()
        },
        params
      )
    )
  end

  defp default_reason("sponsor_application.claim"), do: "review_started"
  defp default_reason("sponsor_application.request_changes"), do: "missing_information"

  @changes %{"fields" => ["goals"], "message" => "  Please describe the events you'd support.  "}

  defp claimed!(r, app) do
    {:ok, _} = exec(r, "sponsor_application.claim", app)
    Repo.reload!(app)
  end

  defp events(command),
    do:
      Repo.all(
        from(e in AuditEvent, where: e.command == ^command, order_by: [e.occurred_at, e.id])
      )

  describe "reading" do
    test "an operator with the read permission sees the submission; each view is audited", c do
      assert {:ok, %{application: %Application{id: id}, latest_submission: %{sequence: 1}}} =
               Operators.get_sponsor_application(c.r.user, c.r.session, c.app.id)

      assert id == c.app.id

      assert [%{action: "sponsor_application.viewed", outcome: :allowed}] =
               Repo.all(
                 from(e in AuditEvent,
                   where: e.action == "sponsor_application.viewed" and e.target_id == ^c.app.id
                 )
               )
    end

    test "drafts, unknown ids and non-operators are not found", c do
      other = registered!("drafter")
      draft = draft!(other)

      assert {:error, :not_found} =
               Operators.get_sponsor_application(c.r.user, c.r.session, draft.id)

      assert {:error, :not_found} =
               Operators.get_sponsor_application(c.r.user, c.r.session, Ecto.UUID.generate())

      plain = registered!("plain")

      assert {:error, :not_found} =
               Operators.get_sponsor_application(plain, live_session!(plain), c.app.id)
    end
  end

  describe "claiming" do
    test "submitted -> under_review, audited, with nothing commercial created", c do
      assert {:ok, %{application: %{status: :under_review}}} =
               exec(c.r, "sponsor_application.claim", c.app)

      assert [%{outcome: :allowed, from_state: "submitted", to_state: "under_review"}] =
               events("sponsor_application.claim")

      assert Repo.aggregate(Organization, :count) == 0
      assert Repo.aggregate(Membership, :count) == 0

      # Claiming again is a conflict (it isn't `submitted` any more).
      assert {:error, {:conflict, %{status: "under_review"}}} =
               exec(c.r, "sponsor_application.claim", c.app)
    end

    test "a repeat of the same operation changes nothing", c do
      params = %{"operation_id" => Ecto.UUID.generate(), "expected_revision" => c.app.revision}
      assert {:ok, first} = exec(c.r, "sponsor_application.claim", c.app, params)
      assert {:ok, again} = exec(c.r, "sponsor_application.claim", c.app, params)
      assert first.application.revision == again.application.revision
      assert length(events("sponsor_application.claim")) == 1
    end

    test "a stale revision is refused", c do
      assert {:error, {:revision_conflict, _}} =
               exec(c.r, "sponsor_application.claim", c.app, %{
                 "expected_revision" => c.app.revision + 1
               })
    end

    test "never on the operator's own application", c do
      own = submitted!(c.r.user, draft!(c.r.user))

      assert {:error, {:conflict, %{target: "self"}}} =
               exec(c.r, "sponsor_application.claim", own)

      assert Repo.reload!(own).status == :submitted
    end

    test "needs the claim permission and a fresh key check", c do
      reader = reviewer!(c.r, "reader", ["sponsors.applications.read"])
      assert {:error, :forbidden} = exec(reader, "sponsor_application.claim", c.app)

      old = DateTime.add(DateTime.utc_now(), -(Policy.fresh_window() + 60))

      Repo.update_all(from(x in StepUp, where: x.operator_id == ^c.r.operator.id),
        set: [verified_at: old]
      )

      assert {:error, :step_up_required} = exec(c.r, "sponsor_application.claim", c.app)
      assert Repo.reload!(c.app).status == :submitted
    end
  end

  describe "requesting changes" do
    test "under_review -> changes_requested with the fields and a message; the applicant is told",
         c do
      app = claimed!(c.r, c.app)

      assert {:ok, %{application: %{status: :changes_requested}, change_request: request}} =
               exec(c.r, "sponsor_application.request_changes", app, @changes)

      assert %{
               fields: ["goals"],
               message: "Please describe the events you'd support.",
               reason_code: "missing_information",
               resolved_at: nil
             } = request

      assert [%{kind: :changes_requested, recipient: :applicant, status: :queued}] =
               Repo.all(
                 from(n in ApplicationNotification,
                   where: n.application_id == ^app.id and n.kind == :changes_requested
                 )
               )

      # The message isn't in the audit log.
      refute inspect(events("sponsor_application.request_changes")) =~ "events you'd support"
    end

    test "only from under_review, with valid fields and a message", c do
      assert {:error, {:conflict, %{status: "submitted"}}} =
               exec(c.r, "sponsor_application.request_changes", c.app, @changes)

      app = claimed!(c.r, c.app)

      for bad <- [
            %{"fields" => [], "message" => "x"},
            %{"fields" => ["password"], "message" => "x"},
            %{"fields" => ["goals", "goals"], "message" => "x"},
            %{"fields" => ["goals"], "message" => "   "},
            %{"fields" => ["goals"], "message" => String.duplicate("a", 2001)}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 exec(c.r, "sponsor_application.request_changes", app, bad),
               inspect(bad)
      end

      assert {:error, _} =
               exec(
                 c.r,
                 "sponsor_application.request_changes",
                 app,
                 %{
                   "reason_code" => "approved"
                 }
                 |> Map.merge(@changes)
               )

      assert Repo.aggregate(ApplicationChangeRequest, :count) == 0
    end

    test "needs the request_changes permission", c do
      claimer = reviewer!(c.r, "claimer", ["sponsors.applications.claim"])
      app = claimed!(claimer, c.app)

      assert {:error, :forbidden} =
               exec(claimer, "sponsor_application.request_changes", app, @changes)
    end
  end

  describe "the applicant after a change request" do
    setup c do
      app = claimed!(c.r, c.app)
      {:ok, _} = exec(c.r, "sponsor_application.request_changes", app, @changes)
      %{app: Repo.reload!(app)}
    end

    test "can change only the requested answers; unchanged answers may be sent again", c do
      assert {:error, %Ecto.Changeset{} = cs} =
               Applications.save(c.applicant, %{
                 "expected_revision" => c.app.revision,
                 "company_name" => "Other Name"
               })

      assert SimpleFitWeb.ChangesetErrors.details(cs).field_codes == %{
               "company_name" => ["not_requested"]
             }

      assert {:ok, %{application: %{goals: "New goals."}}} =
               Applications.save(
                 c.applicant,
                 complete_answers(%{"goals" => "New goals."})
                 |> Map.put("expected_revision", c.app.revision)
               )
    end

    test "resubmitting resolves the request and returns it to review", c do
      {:ok, view} =
        Applications.save(c.applicant, %{
          "expected_revision" => c.app.revision,
          "goals" => "New goals."
        })

      {:ok, view} = Applications.submit(c.applicant, submit_params(view.application))

      assert view.application.status == :submitted
      assert view.change_request == nil

      assert [%{resolved_at: %DateTime{}, resolved_by_submission_id: sid}] =
               Repo.all(ApplicationChangeRequest)

      assert sid == List.last(view.submissions).id
      assert length(view.submissions) == 2
    end

    test "a change request can't be edited or deleted" do
      [request] = Repo.all(ApplicationChangeRequest)

      assert_raise Postgrex.Error, fn ->
        Repo.update_all(from(x in ApplicationChangeRequest, where: x.id == ^request.id),
          set: [message: "rewritten"]
        )
      end

      assert_raise Postgrex.Error, fn ->
        Repo.delete_all(from(x in ApplicationChangeRequest, where: x.id == ^request.id))
      end
    end
  end
end
