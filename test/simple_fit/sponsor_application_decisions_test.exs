defmodule SimpleFit.SponsorApplicationDecisionsTest do
  @moduledoc """
  SF-116 in the SQL sandbox: the review queue, document downloads and the operator
  decisions on sponsor applications through the SF-111 framework (approve, reject,
  suspend or reinstate the approved organization), with their confirmations,
  conflicts of interest, provisioning, audit and notifications.
  """

  use SimpleFit.DataCase, async: false
  use Oban.Testing, repo: SimpleFit.Repo

  import SimpleFit.OperatorHelpers
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.VerificationHelpers, only: [stub_storage: 1]
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1, email_user!: 1]

  alias SimpleFit.{Entry, Operators, Sponsors}
  alias SimpleFit.Operators.{AuditEvent, Confirmation, Policy, StepUp}

  alias SimpleFit.Sponsors.{
    Application,
    ApplicationEvent,
    ApplicationNotification,
    Applications,
    Contact,
    Evidence,
    Membership,
    Organization,
    OrganizationEvent,
    Provisioning
  }

  @all ~w(sponsors.applications.read sponsors.applications.claim
          sponsors.applications.request_changes sponsors.applications.approve
          sponsors.applications.reject sponsors.applications.read_files sponsors.restrict
          operators.read operators.manage)

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    r = founder!(@all)
    applicant = email_user!("applicant-#{System.unique_integer([:positive])}@example.com")
    app = submitted!(applicant, draft!(applicant))
    {:ok, _} = exec(r, "sponsor_application.claim", app, %{"reason_code" => "review_started"})
    %{r: r, applicant: applicant, app: Repo.reload!(app)}
  end

  defp founder!(permissions) do
    user = registered!("reviewer")
    session = live_session!(user)
    op = bootstrap!(user, permissions)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

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

  # An action without confirmation (claim).
  defp exec(r, action, app, params) do
    Operators.execute(
      action,
      r.user,
      r.session,
      app.id,
      Map.merge(
        %{
          "expected_revision" => Repo.reload!(app).revision,
          "operation_id" => Ecto.UUID.generate()
        },
        params
      )
    )
  end

  defp decide(r, action, app, params \\ %{}), do: act(r.user, r.session, action, app.id, params)

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp audits(action),
    do:
      Repo.all(
        from(e in AuditEvent, where: e.command == ^action, order_by: [e.occurred_at, e.id])
      )

  describe "approval" do
    test "a preview changes nothing; the execution creates exactly one organization and owner",
         c do
      assert {:ok, execute, preview} =
               confirmed(c.r.user, c.r.session, "sponsor_application.approve", c.app.id)

      assert preview.confirmation.required
      assert "organization_created" in preview.impact
      assert count(Organization) == 0
      assert count(ApplicationNotification) == 1

      assert {:ok, %{application: %{status: :approved}, organization: org}} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 execute
               )

      app = Repo.reload!(c.app)
      assert app.status == :approved and app.decided_at
      assert %Organization{status: :active, provisioning_source: :sponsor_application} = org
      assert org.source_application_id == app.id and org.legal_name == app.company_name

      # Only the applicant, as owner; never the operator, never the contact by email.
      assert [%Membership{user_id: owner, role: :owner, status: :active}] = Repo.all(Membership)
      assert owner == c.applicant.id
      assert [%Contact{kind: :primary, email: "ada@acme.example"}] = Repo.all(Contact)

      assert [%{authority: :sponsor_application}, %{authority: :sponsor_application}] =
               Repo.all(from(e in OrganizationEvent, order_by: e.occurred_at))

      assert [%{outcome: :allowed, reason_code: "review_complete", to_state: "approved"} = audit] =
               audits("sponsor_application.approve")

      assert audit.confirmation_id

      assert [%{kind: :application_approved, status: :queued, recipient: :applicant}] =
               Repo.all(
                 from(n in ApplicationNotification, where: n.kind == :application_approved)
               )

      # The applicant sees an approval and a sponsor id; nothing commercial exists.
      {:ok, view} = Applications.get(c.applicant)
      assert view.application.status == :approved
      assert {:ok, entry} = Entry.resolve(c.applicant, %{"intent" => "sponsor"})
      assert :sponsor_workspace in entry.capabilities
    end

    test "a repeat of the same request changes nothing; a reused id with another body is refused",
         c do
      {:ok, execute, _} =
        confirmed(c.r.user, c.r.session, "sponsor_application.approve", c.app.id)

      assert {:ok, first} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 execute
               )

      assert {:ok, again} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 execute
               )

      assert first.organization.id == again.organization.id
      assert count(Organization) == 1 and count(Membership) == 1

      assert length(
               audits("sponsor_application.approve")
               |> Enum.filter(&(&1.outcome == :allowed))
             ) == 1

      assert {:error, {:conflict, %{operation_id: "reused"}}} =
               Operators.execute(
                 "sponsor_application.reject",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 Map.put(execute, "reason_code", "other")
               )
    end

    test "confirmations: missing, for another action, for another application, stale, replayed",
         c do
      params = %{"reason_code" => "review_complete", "expected_revision" => c.app.revision}

      assert {:error, :confirmation_required} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 Map.put(params, "operation_id", Ecto.UUID.generate())
               )

      # A rejection's confirmation can't approve.
      {:ok, reject, _} = confirmed(c.r.user, c.r.session, "sponsor_application.reject", c.app.id)

      assert {:error, :confirmation_invalid} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 Map.merge(params, %{
                   "operation_id" => Ecto.UUID.generate(),
                   "confirmation_token" => reject["confirmation_token"]
                 })
               )

      # Another application's confirmation can't approve this one.
      other_applicant = email_user!("other-#{System.unique_integer([:positive])}@example.com")
      other = submitted!(other_applicant, draft!(other_applicant))

      {:ok, _} =
        exec(c.r, "sponsor_application.claim", other, %{"reason_code" => "review_started"})

      {:ok, foreign, _} =
        confirmed(c.r.user, c.r.session, "sponsor_application.approve", other.id)

      assert {:error, :confirmation_invalid} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 Map.merge(params, %{
                   "operation_id" => Ecto.UUID.generate(),
                   "confirmation_token" => foreign["confirmation_token"]
                 })
               )

      # A stale revision is refused before anything else happens.
      {:ok, mine, _} = confirmed(c.r.user, c.r.session, "sponsor_application.approve", c.app.id)

      assert {:error, {:revision_conflict, _}} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 Map.put(mine, "expected_revision", c.app.revision + 1)
               )

      # Used once; a new operation id can't use it again.
      assert {:ok, _} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 mine
               )

      assert count(Organization) == 1
    end

    test "only an application under review, with its own permission and a fresh key check", c do
      reader =
        reviewer!(c.r, "reader", ["sponsors.applications.read", "sponsors.applications.reject"])

      assert {:error, :forbidden} = decide(reader, "sponsor_application.approve", c.app)

      old = DateTime.add(DateTime.utc_now(), -(Policy.fresh_window() + 60))

      Repo.update_all(from(x in StepUp, where: x.operator_id == ^c.r.operator.id),
        set: [verified_at: old]
      )

      assert {:error, :step_up_required} = decide(c.r, "sponsor_application.approve", c.app)
      assert Repo.reload!(c.app).status == :under_review
      assert count(Organization) == 0

      assert [_ | _] =
               Enum.filter(audits("sponsor_application.approve"), &(&1.outcome == :refused))
    end

    test "never on a submitted, changes-requested or decided application", c do
      fresh_user = email_user!("fresh-#{System.unique_integer([:positive])}@example.com")
      fresh = submitted!(fresh_user, draft!(fresh_user))

      assert {:error, {:conflict, %{status: "submitted"}}} =
               decide(c.r, "sponsor_application.approve", fresh)

      assert {:ok, _} = decide(c.r, "sponsor_application.reject", c.app)

      assert {:error, {:conflict, %{status: "rejected"}}} =
               decide(c.r, "sponsor_application.approve", c.app)

      assert count(Organization) == 0
    end

    test "an organization that can't be provisioned leaves the application unapproved", c do
      # Race G: something already holds this application's provisioning key.
      {:ok, fixture} = Provisioning.local_fixture_authority()

      {:ok, _} =
        Provisioning.provision_organization(fixture, %{
          provisioning_key: c.app.id,
          legal_name: "Someone else",
          display_name: "Someone else",
          country_code: "PL",
          owner_user_id: registered!("other-owner").id,
          contacts: [%{kind: "primary", full_name: "X", email: "x@example.com"}]
        })

      notifications = count(ApplicationNotification)

      assert {:error, {:conflict, %{provisioning_key: "reused"}}} =
               decide(c.r, "sponsor_application.approve", c.app)

      assert Repo.reload!(c.app).status == :under_review
      assert Repo.reload!(c.app).decided_at == nil
      assert count(ApplicationNotification) == notifications

      refute Repo.exists?(
               from(e in ApplicationEvent, where: e.event == "sponsor_application.approved")
             )

      assert Enum.all?(audits("sponsor_application.approve"), &(&1.outcome != :allowed))
    end
  end

  describe "conflicts of interest" do
    test "an operator can't decide their own application", c do
      own = submitted!(c.r.user, draft!(c.r.user))
      other = reviewer!(c.r, "claimer", ["sponsors.applications.claim"])

      {:ok, _} =
        exec(other, "sponsor_application.claim", own, %{"reason_code" => "review_started"})

      for action <- ~w(sponsor_application.approve sponsor_application.reject) do
        assert {:error, {:conflict, %{target: "self"}}} =
                 Operators.preview(action, c.r.user, c.r.session, own.id, %{
                   "reason_code" => reason(action)
                 })
      end

      assert Repo.reload!(own).status == :under_review
    end

    test "a member of the approved organization can't restrict it; membership grants no review",
         c do
      {:ok, _} = decide(c.r, "sponsor_application.approve", c.app)
      org = Repo.one!(Organization)

      # The applicant (owner) isn't an operator: everything is not found.
      applicant_session = live_session!(c.applicant)

      assert {:error, :not_found} =
               Operators.get_sponsor_application(c.applicant, applicant_session, c.app.id)

      assert {:error, :not_found} =
               Operators.list_sponsor_applications(c.applicant, applicant_session, %{})

      # An operator who is also a member of that organization is a party to it.
      member_op = reviewer!(c.r, "member-op", ["sponsors.restrict", "sponsors.applications.read"])
      {:ok, fixture} = Provisioning.local_fixture_authority()
      {:ok, _} = Provisioning.add_member(fixture, org.id, member_op.user.id, :member)

      assert {:error, {:conflict, %{target: "self"}}} =
               decide(member_op, "sponsor_application.suspend_organization", c.app)

      assert Repo.reload!(org).status == :active
    end
  end

  describe "rejection" do
    test "under_review -> rejected: final, nothing created, the applicant told without a reason",
         c do
      assert {:ok, %{application: %{status: :rejected}, organization: nil}} =
               decide(c.r, "sponsor_application.reject", c.app)

      assert Repo.reload!(c.app).decided_at
      assert count(Organization) == 0 and count(Membership) == 0

      assert [%{kind: :application_rejected}] =
               Repo.all(
                 from(n in ApplicationNotification, where: n.kind == :application_rejected)
               )

      assert [%{reason_code: "insufficient_information", to_status: "rejected"}] =
               Repo.all(
                 from(e in ApplicationEvent, where: e.event == "sponsor_application.rejected")
               )

      {:ok, view} = Applications.get(c.applicant)
      assert view.application.status == :rejected
      refute inspect(view) =~ "insufficient_information"

      assert {:error, {:conflict, %{status: "rejected"}}} =
               decide(c.r, "sponsor_application.reject", c.app)
    end

    test "only listed reason codes", c do
      assert {:error, %Ecto.Changeset{}} =
               Operators.preview("sponsor_application.reject", c.r.user, c.r.session, c.app.id, %{
                 "reason_code" => "because I said so"
               })
    end
  end

  describe "suspending and reinstating the approved organization" do
    test "only an approved application's active organization; nothing deleted, others untouched",
         c do
      assert {:error, {:conflict, %{status: "under_review"}}} =
               decide(c.r, "sponsor_application.suspend_organization", c.app)

      {:ok, _} = decide(c.r, "sponsor_application.approve", c.app)
      org = Repo.one!(Organization)

      # An unrelated organization, provisioned independently.
      {:ok, fixture} = Provisioning.local_fixture_authority()

      {:ok, %{organization: unrelated}} =
        Provisioning.provision_organization(fixture, %{
          provisioning_key: Ecto.UUID.generate(),
          legal_name: "Unrelated",
          display_name: "Unrelated",
          country_code: "DE",
          owner_user_id: c.applicant.id,
          contacts: [%{kind: "primary", full_name: "Y", email: "y@example.com"}]
        })

      assert {:ok, _} = decide(c.r, "sponsor_application.suspend_organization", c.app)
      assert Repo.reload!(org).status == :suspended
      assert Repo.reload!(unrelated).status == :active
      assert Repo.reload!(c.app).status == :approved
      assert count(Membership) == 2

      assert [
               %{
                 authority: :platform_operator,
                 actor_user_id: actor,
                 reason_code: "approval_mistaken"
               }
             ] =
               Repo.all(from(e in OrganizationEvent, where: e.event == "organization.suspended"))

      assert actor == c.r.user.id

      assert {:error, {:conflict, %{organization: "suspended"}}} =
               decide(c.r, "sponsor_application.suspend_organization", c.app)

      assert {:ok, _} = decide(c.r, "sponsor_application.reinstate_organization", c.app)
      assert Repo.reload!(org).status == :active
    end
  end

  describe "suspension enforces SF-112's access policy on every path" do
    test "no workspace capability or entry while suspended; reads stay; history kept; reinstated back",
         c do
      {:ok, _} = decide(c.r, "sponsor_application.approve", c.app)
      org = Repo.one!(Organization)
      assert {:ok, _} = Sponsors.workspace(c.applicant, org.id)

      {:ok, _} = decide(c.r, "sponsor_application.suspend_organization", c.app)

      # Read-only: the organization and its members are still readable by the member...
      assert {:ok, _} = Sponsors.get_organization(c.applicant, org.id)
      assert {:ok, _} = Sponsors.list_members(c.applicant, org.id)
      # ...but it is no workspace: no capability, no entry destination, no context choice.
      assert {:error, :not_found} = Sponsors.workspace(c.applicant, org.id)
      {:ok, entry} = Entry.resolve(c.applicant, %{"intent" => "sponsor"})
      refute :sponsor_workspace in entry.capabilities
      refute entry.destination == :sponsor_home

      {:ok, chosen} =
        Entry.resolve(c.applicant, %{"context" => "sponsor", "sponsor_id" => org.id})

      assert chosen.context == nil and chosen.sponsor_id == nil
      refute chosen.destination == :sponsor_home

      # Nothing was deleted: membership, application decision and history remain.
      assert [%Membership{status: :active, role: :owner}] = Repo.all(Membership)
      assert Repo.reload!(c.app).status == :approved

      assert Repo.exists?(
               from(e in OrganizationEvent, where: e.event == "organization.suspended")
             )

      {:ok, _} = decide(c.r, "sponsor_application.reinstate_organization", c.app)
      assert {:ok, _} = Sponsors.workspace(c.applicant, org.id)
      {:ok, entry} = Entry.resolve(c.applicant, %{"intent" => "sponsor"})
      assert :sponsor_workspace in entry.capabilities
    end

    test "reinstatement needs its permission, a fresh key check and a confirmation", c do
      {:ok, _} = decide(c.r, "sponsor_application.approve", c.app)
      {:ok, _} = decide(c.r, "sponsor_application.suspend_organization", c.app)

      reader = reviewer!(c.r, "reader-only", ["sponsors.applications.read"])

      assert {:error, :forbidden} =
               decide(reader, "sponsor_application.reinstate_organization", c.app)

      assert {:error, :confirmation_required} =
               Operators.execute(
                 "sponsor_application.reinstate_organization",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 %{
                   "reason_code" => "concern_resolved",
                   "expected_revision" => Repo.reload!(c.app).revision,
                   "operation_id" => Ecto.UUID.generate()
                 }
               )

      assert Repo.one!(Organization).status == :suspended
    end
  end

  describe "confirmations are bound to the operator, the session and time" do
    test "another operator, another session of the same operator, or an expired one can't use it",
         c do
      {:ok, execute, _} =
        confirmed(c.r.user, c.r.session, "sponsor_application.approve", c.app.id)

      # Another operator with the same permission.
      other = reviewer!(c.r, "other", ["sponsors.applications.approve"])

      assert {:error, :confirmation_invalid} =
               Operators.execute(
                 "sponsor_application.approve",
                 other.user,
                 other.session,
                 c.app.id,
                 %{
                   execute
                   | "operation_id" => Ecto.UUID.generate()
                 }
               )

      # The same operator in another session (with its own fresh key check).
      second = live_session!(c.r.user)
      _ = step_up!(c.r.user, second, c.r.key)

      assert {:error, :confirmation_invalid} =
               Operators.execute("sponsor_application.approve", c.r.user, second, c.app.id, %{
                 execute
                 | "operation_id" => Ecto.UUID.generate()
               })

      # Expired: the same binding, issued in the past (confirmations can't be edited).
      real = Repo.one!(from(x in Confirmation, where: x.action == "sponsor_application.approve"))
      token = "sfc_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      past = DateTime.add(DateTime.utc_now(), -10)

      Repo.insert!(
        Ecto.put_meta(
          %{
            real
            | id: nil,
              token_sha256: :crypto.hash(:sha256, token),
              inserted_at: DateTime.add(past, -Policy.confirmation_ttl()),
              expires_at: past
          },
          state: :built
        )
      )

      assert {:error, :confirmation_invalid} =
               Operators.execute(
                 "sponsor_application.approve",
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 %{
                   execute
                   | "operation_id" => Ecto.UUID.generate(),
                     "confirmation_token" => token
                 }
               )

      assert Repo.reload!(c.app).status == :under_review
      assert count(Organization) == 0
    end

    test "an operator who never passed a key check in this session can't decide", c do
      fresh_session = live_session!(c.r.user)

      assert {:error, :step_up_required} =
               Operators.preview(
                 "sponsor_application.approve",
                 c.r.user,
                 fresh_session,
                 c.app.id,
                 %{
                   "reason_code" => "review_complete"
                 }
               )
    end
  end

  describe "the queue" do
    test "submitted applications only, oldest first, paged by a cursor bound to its reader", c do
      drafter = registered!("drafter")
      _draft = draft!(drafter)

      others =
        for i <- 1..3 do
          u = email_user!("q#{i}-#{System.unique_integer([:positive])}@example.com")
          submitted!(u, draft!(u))
        end

      {:ok, page} = Operators.list_sponsor_applications(c.r.user, c.r.session, %{"limit" => "2"})
      assert length(page.applications) == 2 and is_binary(page.next_cursor)

      {:ok, rest} =
        Operators.list_sponsor_applications(c.r.user, c.r.session, %{
          "limit" => "2",
          "cursor" => page.next_cursor
        })

      ids = Enum.map(page.applications ++ rest.applications, & &1.application.id)
      assert ids == Enum.map([c.app | others], & &1.id)
      assert rest.next_cursor == nil

      row = hd(page.applications)
      assert row.company_name == "Acme Boxing Gear Sp. z o.o." and row.submissions == 1

      # Filters and cursors: a status filter; a cursor for other filters or tampered is refused.
      {:ok, under} =
        Operators.list_sponsor_applications(c.r.user, c.r.session, %{"status" => "under_review"})

      assert Enum.map(under.applications, & &1.application.id) == [c.app.id]

      assert {:error, %Ecto.Changeset{}} =
               Operators.list_sponsor_applications(c.r.user, c.r.session, %{
                 "status" => "submitted",
                 "cursor" => page.next_cursor
               })

      assert {:error, %Ecto.Changeset{}} =
               Operators.list_sponsor_applications(c.r.user, c.r.session, %{
                 "cursor" => page.next_cursor <> "x"
               })

      assert {:error, %Ecto.Changeset{}} =
               Operators.list_sponsor_applications(c.r.user, c.r.session, %{"status" => "draft"})

      other_reader = reviewer!(c.r, "reader2", ["sponsors.applications.read"])

      assert {:error, %Ecto.Changeset{}} =
               Operators.list_sponsor_applications(other_reader.user, other_reader.session, %{
                 "limit" => "2",
                 "cursor" => page.next_cursor
               })

      assert Repo.exists?(
               from(e in AuditEvent,
                 where: e.action == "sponsor_applications.queue_read" and e.outcome == :allowed
               )
             )
    end
  end

  describe "documents" do
    setup do
      fresh = email_user!("docs-#{System.unique_integer([:positive])}@example.com")
      app = draft!(fresh)

      {:ok, {_view, evidence, _upload}} =
        Evidence.initiate(fresh, %{
          "expected_revision" => app.revision,
          "kind" => "brand_deck",
          "file_name" => "deck.pdf",
          "content_type" => "application/pdf",
          "byte_size" => 100
        })

      stub_storage(%{evidence.id => {100, "application/pdf"}})
      {:ok, _} = Evidence.confirm(fresh, evidence.id)
      app = submitted!(fresh, Repo.reload!(app))
      %{doc_app: app, evidence: evidence}
    end

    test "a short-lived attachment download, audited without the URL", c do
      assert {:ok, download} =
               Operators.download_sponsor_application_document(
                 c.r.user,
                 c.r.session,
                 c.doc_app.id,
                 c.evidence.id
               )

      assert download.method == :get
      assert download.url =~ "response-content-disposition=attachment"
      assert download.url =~ "response-content-type=application%2Foctet-stream"
      assert DateTime.diff(download.expires_at, DateTime.utc_now()) <= 300

      assert [audit] =
               Repo.all(
                 from(e in AuditEvent,
                   where:
                     e.action == "sponsor_application.file_downloaded" and e.outcome == :allowed
                 )
               )

      assert audit.target_id == c.evidence.id
      refute inspect(Map.from_struct(audit)) =~ download.url
    end

    test "needs read_files; never another application's or an unsubmitted document", c do
      reader = reviewer!(c.r, "nofiles", ["sponsors.applications.read"])

      assert {:error, :forbidden} =
               Operators.download_sponsor_application_document(
                 reader.user,
                 reader.session,
                 c.doc_app.id,
                 c.evidence.id
               )

      # The document named under another application.
      assert {:error, :not_found} =
               Operators.download_sponsor_application_document(
                 c.r.user,
                 c.r.session,
                 c.app.id,
                 c.evidence.id
               )

      assert {:error, :not_found} =
               Operators.download_sponsor_application_document(
                 c.r.user,
                 c.r.session,
                 c.doc_app.id,
                 Ecto.UUID.generate()
               )

      # Not an operator at all.
      plain = registered!("plain")

      assert {:error, :not_found} =
               Operators.download_sponsor_application_document(
                 plain,
                 live_session!(plain),
                 c.doc_app.id,
                 c.evidence.id
               )
    end
  end

  test "operator revocation removes review authority", c do
    reviewer =
      reviewer!(c.r, "leaving", ["sponsors.applications.approve", "sponsors.applications.read"])

    {:ok, revoke, _} = confirmed(c.r.user, c.r.session, "operator.revoke", reviewer.operator.id)
    {:ok, _} = Operators.revoke(c.r.user, c.r.session, reviewer.operator.id, revoke)

    assert {:error, :not_found} = decide(reviewer, "sponsor_application.approve", c.app)
    assert Repo.reload!(c.app).status == :under_review
    assert %Application{} = Repo.reload!(c.app)
  end
end
