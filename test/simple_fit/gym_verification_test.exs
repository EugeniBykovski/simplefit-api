defmodule SimpleFit.GymVerificationTest do
  @moduledoc """
  Gym business verification and go-live readiness (SF-103) through
  `SimpleFit.Gyms` and the operator module: the owner's draft, documents
  verified against storage, submission, revisions, authorization, operator
  decisions and their guards, revocation, independence from Stripe, SaaS
  billing and gym operations, the readiness evaluator and the storage
  cleanup. The clock is frozen.
  """

  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import SimpleFit.BookingHelpers
  import SimpleFit.GymHelpers
  import SimpleFit.VerificationHelpers

  alias SimpleFit.Billing.Stripe.ConnectedAccount
  alias SimpleFit.{Clock, Gyms, Repo}

  alias SimpleFit.Gyms.{
    AuditEvent,
    ClassBooking,
    ClassOccurrence,
    GoLive,
    Member,
    VerificationApplication,
    VerificationCleanupWorker,
    VerificationEvent,
    VerificationEvidence,
    VerificationReview
  }

  # Monday 5 January 2026, winter time in Warsaw (UTC+1).
  @now ~U[2026-01-05 12:00:00Z]
  @wednesday "2026-01-07T18:00:00+01:00"

  setup do
    Clock.freeze(@now)
    Repo.delete_all("rate_limit_events")
    on_exit(&Clock.unfreeze/0)
    stub_storage(%{})

    owner = registered_as!(registered!("kyb-owner"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym}
  end

  defp session(user), do: live_session!(user)
  defp get!(user, gym_id), do: elem(Gyms.get_business_verification(user, gym_id), 1)

  defp save(user, gym_id, attrs),
    do: Gyms.save_business_verification(user, session(user), gym_id, attrs)

  defp submit(user, gym_id, revision),
    do: Gyms.submit_business_verification(user, session(user), gym_id, %{"revision" => revision})

  defp announce(user, gym_id, attrs) do
    revision = get!(user, gym_id).application.revision

    Gyms.add_business_verification_evidence(
      user,
      session(user),
      gym_id,
      Map.merge(
        %{
          "revision" => revision,
          "kind" => "proof_of_address",
          "file_name" => "lease.pdf",
          "content_type" => "application/pdf",
          "byte_size" => 1000
        },
        attrs
      )
    )
  end

  defp confirm(user, gym_id, evidence_id),
    do: Gyms.confirm_business_verification_evidence(user, session(user), gym_id, evidence_id)

  defp remove(user, gym_id, evidence_id, revision),
    do:
      Gyms.remove_business_verification_evidence(user, session(user), gym_id, evidence_id, %{
        "revision" => revision
      })

  defp events(application_id),
    do:
      Repo.all(
        from(e in VerificationEvent,
          where: e.application_id == ^application_id,
          order_by: [asc: e.seq]
        )
      )

  defp audit_types(gym_id),
    do:
      Repo.all(
        from(e in AuditEvent,
          where: e.gym_id == ^gym_id and like(type(e.event_type, :string), "business_%"),
          order_by: [asc: e.event_type],
          select: {e.event_type, e.actor_user_id}
        )
      )

  defp check(readiness, key), do: Enum.find(readiness.checks, &(&1.key == key))

  defp decide(view, decision, opts \\ []) do
    VerificationReview.decide(
      view.application.id,
      decision,
      Keyword.merge([revision: view.application.revision, operator: operator()], opts)
    )
  end

  describe "the owner's draft" do
    test "nothing exists until the owner saves; the first save creates revision 1", ctx do
      view = get!(ctx.owner, ctx.gym.id)

      assert %{status: :not_started, application: nil, evidence: [], can_submit: false} = view
      assert view.missing == [:legal_name, :registration_country, :evidence]
      assert view.requirements.policy_version == "sf103-generic-1"
      assert Repo.aggregate(VerificationApplication, :count) == 0

      assert {:ok, {draft, :created}} = save(ctx.owner, ctx.gym.id, details())
      assert draft.status == :draft
      assert draft.application.revision == 1
      assert draft.application.registration_country == "PL"
      assert draft.application.legal_name == "Simple Boxing Sp. z o.o."
      assert draft.missing == [:evidence]
      refute draft.can_submit
    end

    test "changes name the revision; a stale one never overwrites", ctx do
      draft!(ctx.owner, ctx.gym.id, %{"legal_name" => "First name"})

      assert {:ok, {updated, :updated}} =
               save(ctx.owner, ctx.gym.id, %{"revision" => 1, "city" => "Kraków"})

      assert updated.application.revision == 2

      assert {:error, {:conflict, %{revision: "stale", current_revision: 2}}} =
               save(ctx.owner, ctx.gym.id, %{"revision" => 1, "legal_name" => "Old tab"})

      assert {:error, {:conflict, %{revision: "stale", current_revision: 2}}} =
               save(ctx.owner, ctx.gym.id, %{"legal_name" => "No revision"})

      assert get!(ctx.owner, ctx.gym.id).application.legal_name == "First name"

      # Saving nothing new keeps the revision.
      assert {:ok, {same, :updated}} =
               save(ctx.owner, ctx.gym.id, %{"revision" => 2, "city" => "Kraków"})

      assert same.application.revision == 2
    end

    test "invalid values and unknown fields are validation errors (no status, no approval flag)",
         ctx do
      for attrs <- [
            %{"registration_country" => "XX"},
            %{"website" => "javascript:alert(1)"},
            %{"legal_name" => String.duplicate("a", 201)},
            %{"legal_name" => "Bad\u0000name"},
            %{"status" => "approved"},
            %{"verified" => true},
            %{"decided_at" => "2026-01-01T00:00:00Z"},
            %{"revision" => "1"}
          ] do
        assert {:error, %Ecto.Changeset{}} = save(ctx.owner, ctx.gym.id, attrs), inspect(attrs)
      end

      assert Repo.aggregate(VerificationApplication, :count) == 0
    end
  end

  describe "documents" do
    setup ctx do
      draft!(ctx.owner, ctx.gym.id)
      :ok
    end

    test "announce, upload, confirm: the server checks the stored object itself", ctx do
      assert {:ok, {view, evidence, upload}} =
               announce(ctx.owner, ctx.gym.id, %{"file_name" => "C:\\scans\\lease.pdf"})

      assert evidence.status == :pending_upload
      assert evidence.file_name == "lease.pdf"
      assert upload.method == :put
      assert upload.headers == %{"content-type" => "application/pdf", "content-length" => "1000"}

      assert evidence.object_key ==
               "gyms/#{ctx.gym.id}/business-verification/#{view.application.id}/#{evidence.id}"

      refute view.can_submit
      assert view.application.revision == 2

      # Nothing uploaded yet.
      assert {:error, {:conflict, %{upload: "not_found"}}} =
               confirm(ctx.owner, ctx.gym.id, evidence.id)

      # A different object (size or type) never attaches.
      stub_storage(%{evidence.id => {999, "application/pdf"}})

      assert {:error, {:conflict, %{upload: "mismatch"}}} =
               confirm(ctx.owner, ctx.gym.id, evidence.id)

      stub_storage(%{evidence.id => {1000, "text/html"}})

      assert {:error, {:conflict, %{upload: "mismatch"}}} =
               confirm(ctx.owner, ctx.gym.id, evidence.id)

      stub_storage(%{evidence.id => {1000, "application/pdf; charset=binary"}})
      assert {:ok, confirmed} = confirm(ctx.owner, ctx.gym.id, evidence.id)
      assert [%{status: :uploaded}] = confirmed.evidence
      assert confirmed.can_submit
      assert confirmed.missing == []

      # Confirming again answers the same.
      assert {:ok, ^confirmed} = confirm(ctx.owner, ctx.gym.id, evidence.id)
    end

    test "a storage failure attaches nothing and is retryable", ctx do
      {:ok, {_view, evidence, _upload}} = announce(ctx.owner, ctx.gym.id, %{})
      Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, 503, ""))

      assert capture_log(fn ->
               assert {:error, :unavailable} = confirm(ctx.owner, ctx.gym.id, evidence.id)
             end) =~ "provider request failed"

      assert Repo.get!(VerificationEvidence, evidence.id).status == :pending_upload
    end

    test "the policy bounds kind, type, size, name and count", ctx do
      for attrs <- [
            %{"kind" => "selfie"},
            %{"content_type" => "image/svg+xml"},
            %{"content_type" => "text/html"},
            %{"byte_size" => 0},
            %{"byte_size" => 10 * 1024 * 1024 + 1},
            %{"file_name" => "///"},
            %{"object_key" => "gyms/other/evil.pdf"},
            %{"url" => "https://evil.example/x.pdf"}
          ] do
        assert {:error, %Ecto.Changeset{}} = announce(ctx.owner, ctx.gym.id, attrs),
               inspect(attrs)
      end

      for _ <- 1..10, do: assert({:ok, _} = announce(ctx.owner, ctx.gym.id, %{}))

      assert {:error, {:conflict, %{evidence: "limit_reached"}}} =
               announce(ctx.owner, ctx.gym.id, %{})
    end

    test "pending uploads block submission; removing one unblocks it", ctx do
      {_view, _uploaded, _objects} = upload!(ctx.owner, ctx.gym.id)
      {:ok, {view, pending, _upload}} = announce(ctx.owner, ctx.gym.id, %{})
      refute view.can_submit

      assert {:error, {:conflict, %{evidence: "upload_pending"}}} =
               submit(ctx.owner, ctx.gym.id, view.application.revision)

      assert {:ok, removed} = remove(ctx.owner, ctx.gym.id, pending.id, view.application.revision)
      assert removed.can_submit
      assert length(removed.evidence) == 1

      # Removing again answers the same; confirming it is refused.
      assert {:ok, _} = remove(ctx.owner, ctx.gym.id, pending.id, removed.application.revision)

      assert {:error, {:conflict, %{evidence: "removed"}}} =
               confirm(ctx.owner, ctx.gym.id, pending.id)
    end

    test "a stale form cannot add or remove documents", ctx do
      {view, evidence_id, _objects} = upload!(ctx.owner, ctx.gym.id)
      old = view.application.revision - 1

      assert {:error, {:conflict, %{revision: "stale"}}} =
               announce(ctx.owner, ctx.gym.id, %{"revision" => old})

      assert {:error, {:conflict, %{revision: "stale"}}} =
               remove(ctx.owner, ctx.gym.id, evidence_id, old)

      assert {:error, {:conflict, %{revision: "stale"}}} = submit(ctx.owner, ctx.gym.id, old)
    end

    test "unknown, foreign and malformed document ids are not found", ctx do
      other_owner = registered!("kyb-other")
      other_gym = completed_gym!(other_owner)
      draft!(other_owner, other_gym.id)
      {:ok, {_v, foreign, _u}} = announce(other_owner, other_gym.id, %{})
      revision = get!(ctx.owner, ctx.gym.id).application.revision

      for id <- [foreign.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :not_found} = confirm(ctx.owner, ctx.gym.id, id)
        assert {:error, :not_found} = remove(ctx.owner, ctx.gym.id, id, revision)
      end
    end
  end

  describe "submission" do
    test "requires the policy's fields and a confirmed document", ctx do
      draft!(ctx.owner, ctx.gym.id, %{"city" => "Warszawa"})

      assert {:error, %Ecto.Changeset{} = changeset} = submit(ctx.owner, ctx.gym.id, 1)

      assert Keyword.keys(changeset.errors) |> Enum.sort() == [
               :evidence,
               :legal_name,
               :registration_country
             ]

      assert get!(ctx.owner, ctx.gym.id).status == :draft
    end

    test "submits for review without approving; duplicates answer the same", ctx do
      view = submitted!(ctx.owner, ctx.gym.id)

      assert view.status == :submitted
      assert view.latest_decision == nil
      refute view.can_edit
      refute view.can_submit
      assert [%VerificationEvidence{submitted_revision: revision}] = view.evidence

      assert revision == view.application.revision
      assert Gyms.Verification.status(ctx.gym.id) == :submitted

      assert {:ok, ^view} = submit(ctx.owner, ctx.gym.id, view.application.revision)

      assert {:error, {:conflict, %{revision: "stale"}}} =
               submit(ctx.owner, ctx.gym.id, view.application.revision + 1)

      assert {:error, {:conflict, %{verification: "submitted"}}} =
               save(ctx.owner, ctx.gym.id, %{
                 "revision" => view.application.revision,
                 "city" => "Łódź"
               })

      [evidence] = view.evidence

      assert {:error, {:conflict, %{verification: "submitted"}}} =
               remove(ctx.owner, ctx.gym.id, evidence.id, view.application.revision)

      assert [%VerificationEvent{event: :submitted, actor_user_id: owner_id, operator: nil}] =
               events(view.application.id)

      assert owner_id == ctx.owner.id
      assert audit_types(ctx.gym.id) == [{:business_verification_submitted, ctx.owner.id}]
    end

    test "the database refuses a forged approval or a changed submission", ctx do
      view = submitted!(ctx.owner, ctx.gym.id)
      application = Repo.get!(VerificationApplication, view.application.id)

      assert_raise Ecto.ConstraintError, ~r/gym_verification_applications_frozen/, fn ->
        Repo.transaction(fn ->
          application |> Ecto.Changeset.change(legal_name: "Forged") |> Repo.update!()
        end)
      end

      forger = registered!("kyb-forger")
      forger_gym = completed_gym!(forger)
      draft!(forger, forger_gym.id)
      draft = Repo.get_by!(VerificationApplication, gym_id: forger_gym.id)

      assert_raise Ecto.ConstraintError, ~r/gym_verification_applications_transition/, fn ->
        Repo.transaction(fn ->
          draft
          |> Ecto.Changeset.change(status: :approved, decided_at: DateTime.utc_now())
          |> Repo.update!()
        end)
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.transaction(fn ->
          Repo.update_all(VerificationEvent, set: [operator: "someone@else.test"])
        end)
      end
    end
  end

  describe "authorization" do
    test "only the owner reads or writes; staff are forbidden, outsiders not found", ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager, "Mia Manager")
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Cody Coach")
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk, "Fran Desk")
      stranger = registered!("kyb-stranger")
      {member_user, _member} = member!(ctx.owner, ctx.gym.id)

      for user <- [manager, coach, desk] do
        assert {:error, :forbidden} = Gyms.get_business_verification(user, ctx.gym.id)
        assert {:error, :forbidden} = save(user, ctx.gym.id, details())
      end

      for user <- [stranger, member_user] do
        assert {:error, :not_found} = Gyms.get_business_verification(user, ctx.gym.id)
        assert {:error, :not_found} = save(user, ctx.gym.id, details())
      end

      assert {:error, :not_found} =
               Gyms.get_business_verification(ctx.owner, Ecto.UUID.generate())

      assert {:error, :not_found} = Gyms.get_business_verification(ctx.owner, "nope")
      assert Repo.aggregate(VerificationApplication, :count) == 0
    end

    test "another gym's owner cannot read or act on this application", ctx do
      submitted!(ctx.owner, ctx.gym.id)
      other = registered!("kyb-rival")
      completed_gym!(other)

      assert {:error, :not_found} = Gyms.get_business_verification(other, ctx.gym.id)
      assert {:error, :not_found} = submit(other, ctx.gym.id, 1)
    end

    test "authority follows the active owner role; a transfer moves it, membership never grants it",
         ctx do
      view = submitted!(ctx.owner, ctx.gym.id)
      {manager, staff} = joined_staff!(ctx.owner, ctx.gym.id, :manager, "Mia Manager")
      assert {:error, :forbidden} = Gyms.get_business_verification(manager, ctx.gym.id)

      {:ok, _} =
        Gyms.transfer_ownership(
          ctx.owner,
          ctx.gym.id,
          staff.staff_membership_id,
          :stay_as_manager
        )

      assert {:ok, %{status: :submitted}} = Gyms.get_business_verification(manager, ctx.gym.id)
      assert {:error, :forbidden} = Gyms.get_business_verification(ctx.owner, ctx.gym.id)

      # The new owner still cannot decide; the application is unchanged.
      assert Repo.get!(VerificationApplication, view.application.id).status == :submitted
    end

    test "a draft gym cannot start an application" do
      drafter = registered!("kyb-drafter")
      draft = draft_gym!(drafter)

      assert {:error, {:conflict, %{setup_status: "draft"}}} = save(drafter, draft.id, details())
    end
  end

  describe "operator review" do
    test "approval is recorded with the operator, the revision and the documents", ctx do
      view = submitted!(ctx.owner, ctx.gym.id)
      [evidence] = view.evidence

      assert {:ok, %VerificationApplication{status: :approved}} = decide(view, :approved)

      approved = get!(ctx.owner, ctx.gym.id)
      assert approved.status == :approved
      assert %{decision: :approved, reason_code: nil} = approved.latest_decision
      refute approved.can_edit

      assert [_submitted, decision] = events(view.application.id)
      assert decision.event == :approved
      assert decision.operator == operator()
      assert decision.actor_user_id == nil
      assert decision.application_revision == view.application.revision
      assert decision.evidence_ids == [evidence.id]

      assert audit_types(ctx.gym.id) == [
               {:business_verification_approved, nil},
               {:business_verification_submitted, ctx.owner.id}
             ]
    end

    test "decisions need the reviewed revision, a valid reason and a submitted application",
         ctx do
      draft!(ctx.owner, ctx.gym.id)
      draft = get!(ctx.owner, ctx.gym.id)
      assert {:error, {:conflict, %{verification: "draft"}}} = decide(draft, :approved)

      {view, _id, _objects} = upload!(ctx.owner, ctx.gym.id)
      {:ok, view} = submit(ctx.owner, ctx.gym.id, view.application.revision)

      assert {:error, {:conflict, %{revision: "stale"}}} =
               decide(view, :approved, revision: view.application.revision - 1)

      assert {:error, {:invalid, :revision}} = decide(view, :approved, revision: nil)
      assert {:error, {:invalid, :reason}} = decide(view, :rejected)
      assert {:error, {:invalid, :reason}} = decide(view, :rejected, reason: "because")

      assert {:error, {:invalid, :reason}} =
               decide(view, :changes_requested, reason: "suspected_fraud")

      assert {:error, {:invalid, :reason}} = decide(view, :approved, reason: "other")
      assert {:error, {:invalid, :operator}} = decide(view, :approved, operator: "not an email")
      assert {:error, {:invalid, :operator}} = decide(view, :approved, operator: nil)

      assert {:error, :not_found} =
               VerificationReview.decide(Ecto.UUID.generate(), :approved,
                 revision: 1,
                 operator: operator()
               )

      assert {:error, {:conflict, %{verification: "submitted"}}} =
               VerificationReview.revoke(view.application.id,
                 reason: "other",
                 operator: operator()
               )

      assert get!(ctx.owner, ctx.gym.id).status == :submitted
    end

    test "no one at the gym can decide: the owner and staff are refused as operators", ctx do
      link_email!(ctx.owner, "owner@simpleboxing.example")
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager, "Mia Manager")
      link_email!(manager, "mia@simpleboxing.example")
      view = submitted!(ctx.owner, ctx.gym.id)

      for address <- ["owner@simpleboxing.example", " Mia@SimpleBoxing.example "] do
        assert {:error, {:conflict, %{operator: "not_independent"}}} =
                 decide(view, :approved, operator: address)

        assert {:error, {:conflict, %{operator: "not_independent"}}} =
                 VerificationReview.evidence_download(
                   view.application.id,
                   hd(view.evidence).id,
                   address
                 )
      end

      assert get!(ctx.owner, ctx.gym.id).status == :submitted
      assert {:ok, _} = decide(view, :approved)
    end

    test "changes requested: the owner edits, adds a document and resubmits", ctx do
      view = submitted!(ctx.owner, ctx.gym.id)
      [first] = view.evidence
      assert {:ok, _} = decide(view, :changes_requested, reason: "document_unreadable")

      reopened = get!(ctx.owner, ctx.gym.id)
      assert reopened.status == :changes_requested

      assert %{decision: :changes_requested, reason_code: "document_unreadable"} =
               reopened.latest_decision

      assert reopened.can_edit and reopened.can_submit

      # The submitted document is frozen; a new one can be added.
      assert {:error, {:conflict, %{evidence: "submitted"}}} =
               remove(ctx.owner, ctx.gym.id, first.id, reopened.application.revision)

      {:ok, {edited, :updated}} =
        save(ctx.owner, ctx.gym.id, %{
          "revision" => reopened.application.revision,
          "city" => "Kraków"
        })

      {with_second, second_id, _objects} =
        upload!(ctx.owner, ctx.gym.id, %{first.id => {182_311, "application/pdf"}})

      assert with_second.application.revision > edited.application.revision

      {:ok, resubmitted} = submit(ctx.owner, ctx.gym.id, with_second.application.revision)
      assert resubmitted.status == :submitted

      # The operator must review the new revision, and sees both documents.
      assert {:error, {:conflict, %{revision: "stale"}}} = decide(view, :approved)
      assert {:ok, _} = decide(resubmitted, :approved)

      assert [:submitted, :changes_requested, :submitted, :approved] =
               Enum.map(events(view.application.id), & &1.event)

      assert Enum.sort(List.last(events(view.application.id)).evidence_ids) ==
               Enum.sort([first.id, second_id])
    end

    test "after a rejection the owner starts over; old documents never count", ctx do
      view = submitted!(ctx.owner, ctx.gym.id)
      [old] = view.evidence
      assert {:ok, _} = decide(view, :rejected, reason: "business_not_verifiable")

      rejected = get!(ctx.owner, ctx.gym.id)
      assert rejected.status == :rejected
      assert rejected.can_edit
      refute rejected.can_submit
      assert rejected.requirements.policy_version == "sf103-generic-1"

      assert {:ok, {fresh, :created}} = save(ctx.owner, ctx.gym.id, details())
      assert fresh.application.id != view.application.id
      assert fresh.status == :draft
      assert fresh.evidence == []
      assert fresh.missing == [:evidence]

      assert {:error, {:conflict, %{evidence: "upload_pending"}} = _} =
               (fn ->
                  {:ok, {_v, _pending, _u}} = announce(ctx.owner, ctx.gym.id, %{})
                  submit(ctx.owner, ctx.gym.id, get!(ctx.owner, ctx.gym.id).application.revision)
                end).()

      assert {:error, :not_found} =
               remove(
                 ctx.owner,
                 ctx.gym.id,
                 old.id,
                 get!(ctx.owner, ctx.gym.id).application.revision
               )

      assert {:error, :not_found} = confirm(ctx.owner, ctx.gym.id, old.id)
      assert Repo.get!(VerificationApplication, view.application.id).status == :rejected
    end

    test "operators download confirmed documents through short-lived, recorded links", ctx do
      view = submitted!(ctx.owner, ctx.gym.id)
      [evidence] = view.evidence

      assert {:ok, download} =
               VerificationReview.evidence_download(view.application.id, evidence.id, operator())

      assert download.method == :get
      assert DateTime.diff(download.expires_at, DateTime.utc_now()) in 290..300

      assert [_submitted, %{event: :evidence_downloaded, operator: op, evidence_ids: ids}] =
               events(view.application.id)

      assert op == operator()
      assert ids == [evidence.id]

      assert {:error, :not_found} =
               VerificationReview.evidence_download(
                 view.application.id,
                 Ecto.UUID.generate(),
                 operator()
               )
    end

    test "list and show cover submitted applications only", ctx do
      view = submitted!(ctx.owner, ctx.gym.id)
      other = registered!("kyb-other-draft")
      other_gym = completed_gym!(other)
      draft!(other, other_gym.id)

      assert [%{application: %{id: id}, gym_name: _}] = VerificationReview.list_submitted()
      assert id == view.application.id
      assert {:ok, %{evidence: [_], events: [_]}} = VerificationReview.show(id)
      assert {:error, :not_found} = VerificationReview.show("nope")
    end
  end

  describe "revocation" do
    test "withdraws the approval, keeps every gym record, and fails go-live closed", ctx do
      class = class!(ctx.owner, ctx.gym.id, @wednesday, 5)
      {marta, member} = member!(ctx.owner, ctx.gym.id)
      book!(marta, member.gym_member_id, class.occurrence_id)
      approved = approved!(ctx.owner, ctx.gym.id)

      {:ok, before} = Gyms.get_go_live(ctx.owner, ctx.gym.id)
      assert before.prerequisites_met
      assert check(before, :business_verification).status == :passed

      counts = fn ->
        {Repo.aggregate(ClassOccurrence, :count), Repo.aggregate(ClassBooking, :count),
         Repo.aggregate(from(m in Member, where: m.status == :active), :count),
         Repo.aggregate(VerificationEvidence, :count)}
      end

      snapshot = counts.()

      assert {:error, {:invalid, :reason}} =
               VerificationReview.revoke(approved.application.id, operator: operator())

      assert {:ok, %{status: :revoked}} =
               VerificationReview.revoke(approved.application.id,
                 reason: "business_closed",
                 operator: operator()
               )

      assert counts.() == snapshot
      assert get!(ctx.owner, ctx.gym.id).status == :revoked

      {:ok, after_revocation} = Gyms.get_go_live(ctx.owner, ctx.gym.id)
      refute after_revocation.prerequisites_met

      assert %{status: :failed, reason_code: :revoked} =
               check(after_revocation, :business_verification)

      # Revoked is final for that application.
      assert {:error, {:conflict, %{verification: "revoked"}}} =
               VerificationReview.revoke(approved.application.id,
                 reason: "other",
                 operator: operator()
               )

      # The gym keeps operating.
      {piotr, piotr_member} = member!(ctx.owner, ctx.gym.id, "Piotr Zając")
      assert book!(piotr, piotr_member.gym_member_id, class.occurrence_id)
    end
  end

  describe "independence from Stripe, plans and setup" do
    test "Stripe capabilities never verify a business, and approval touches no Stripe record",
         ctx do
      Repo.insert!(%ConnectedAccount{
        mode: :test,
        gym_id: ctx.gym.id,
        stripe_account_id: "acct_kybindependent",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true,
        linked_by: "ops",
        last_synced_at: DateTime.utc_now()
      })

      assert get!(ctx.owner, ctx.gym.id).status == :not_started
      {:ok, readiness} = Gyms.get_go_live(ctx.owner, ctx.gym.id)

      assert %{status: :failed, reason_code: :not_started} =
               check(readiness, :business_verification)

      assert %{status: :blocked, reason_code: :decisions_not_approved} =
               check(readiness, :member_payments)

      stripe_tables = ~w(stripe_customers stripe_prices stripe_checkouts stripe_subscriptions
                         stripe_invoices stripe_connected_accounts gym_saas_subscriptions)

      count_all = fn ->
        Enum.map(stripe_tables, &(Repo.query!("SELECT count(*) FROM #{&1}").rows |> hd() |> hd()))
      end

      before = count_all.()
      approved!(ctx.owner, ctx.gym.id)
      assert count_all.() == before

      account = Repo.get_by!(ConnectedAccount, gym_id: ctx.gym.id)
      assert account.charges_enabled and account.payouts_enabled
    end

    test "a completed setup alone is not verification", ctx do
      {:ok, readiness} = Gyms.get_go_live(ctx.owner, ctx.gym.id)
      assert check(readiness, :setup_completed).status == :passed
      assert check(readiness, :business_verification).status == :failed
      refute readiness.prerequisites_met
    end
  end

  describe "go-live readiness" do
    test "derives every check from real records; publication is unavailable", ctx do
      {:ok, readiness} = Gyms.get_go_live(ctx.owner, ctx.gym.id)

      assert readiness.policy_version == "sf103-golive-1"
      assert DateTime.compare(readiness.evaluated_at, @now) == :eq
      assert Enum.map(readiness.checks, & &1.key) == GoLive.keys()

      assert readiness.publication == %{
               status: :unavailable,
               reason_code: :public_surface_not_available
             }

      assert %{status: :passed, requiredness: :required} = check(readiness, :setup_completed)
      assert %{status: :passed, requiredness: :required} = check(readiness, :primary_location)

      assert %{status: :failed, requiredness: :required, action: :open_verification} =
               check(readiness, :business_verification)

      assert %{status: :failed, requiredness: :recommended} = check(readiness, :upcoming_class)
      assert %{status: :failed, requiredness: :optional} = check(readiness, :staff)
      assert %{status: :failed, requiredness: :optional} = check(readiness, :members)
      assert %{status: :failed, requiredness: :optional} = check(readiness, :member_products)
      assert %{status: :unavailable, requiredness: :future} = check(readiness, :public_profile)

      assert %{status: :unavailable, requiredness: :future} =
               check(readiness, :community_settings)

      refute readiness.prerequisites_met
    end

    test "invitations, requests and pending reviews are not facts; acceptances are", ctx do
      invite!(ctx.owner, ctx.gym.id, address("pending-coach"), :coach)
      code = join_code!(ctx.owner, ctx.gym.id)
      requester!(code)
      submitted!(ctx.owner, ctx.gym.id)

      {:ok, pending} = Gyms.get_go_live(ctx.owner, ctx.gym.id)
      assert %{status: :failed} = check(pending, :staff)
      assert %{status: :failed} = check(pending, :members)
      assert %{status: :pending, reason_code: :in_review} = check(pending, :business_verification)
      refute pending.prerequisites_met

      joined_staff!(ctx.owner, ctx.gym.id, :coach, "Cody Coach")
      active_member!(ctx.owner, ctx.gym.id, code, "Ola Member")
      class!(ctx.owner, ctx.gym.id, @wednesday, 5)
      view = get!(ctx.owner, ctx.gym.id)
      {:ok, _} = decide(view, :approved)

      {:ok, ready} = Gyms.get_go_live(ctx.owner, ctx.gym.id)
      assert %{status: :passed} = check(ready, :staff)
      assert %{status: :passed} = check(ready, :members)
      assert %{status: :passed} = check(ready, :upcoming_class)
      assert %{status: :passed, reason_code: :approved} = check(ready, :business_verification)
      assert ready.prerequisites_met
      assert ready.publication.status == :unavailable

      # A past class is not an upcoming one.
      Clock.freeze(~U[2026-02-01 12:00:00Z])
      {:ok, later} = Gyms.get_go_live(ctx.owner, ctx.gym.id)
      assert %{status: :failed} = check(later, :upcoming_class)
    end

    test "owner and managers read it; coaches and front desk are forbidden", ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager, "Mia Manager")
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach, "Cody Coach")
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk, "Fran Desk")

      assert {:ok, _} = Gyms.get_go_live(manager, ctx.gym.id)
      assert {:error, :forbidden} = Gyms.get_go_live(coach, ctx.gym.id)
      assert {:error, :forbidden} = Gyms.get_go_live(desk, ctx.gym.id)
      assert {:error, :not_found} = Gyms.get_go_live(registered!("kyb-out"), ctx.gym.id)
    end
  end

  describe "storage cleanup" do
    test "deletes abandoned and removed uploads, never submitted ones", ctx do
      view = submitted!(ctx.owner, ctx.gym.id)
      [submitted] = view.evidence

      other = registered!("kyb-cleanup")
      other_gym = completed_gym!(other)
      draft!(other, other_gym.id)
      {:ok, {_v, abandoned, _u}} = announce(other, other_gym.id, %{})
      {:ok, {_v, removed, _u}} = announce(other, other_gym.id, %{})

      {:ok, _} =
        remove(other, other_gym.id, removed.id, get!(other, other_gym.id).application.revision)

      # The day after the upload links expired.
      later = DateTime.add(DateTime.utc_now(), 2 * 86_400)
      assert %{abandoned: 1, deleted: 2} = VerificationCleanupWorker.sweep(later)

      deleted =
        for _ <- 1..2 do
          assert_receive {:storage_deleted, path}
          path
        end

      assert Enum.all?(deleted, &(&1 =~ other_gym.id))
      refute_received {:storage_deleted, _}

      assert %{status: :removed, object_deleted_at: %DateTime{}} =
               Repo.get!(VerificationEvidence, abandoned.id)

      assert %{status: :uploaded, object_deleted_at: nil} =
               Repo.get!(VerificationEvidence, submitted.id)

      # Each object is deleted once.
      assert %{abandoned: 0, deleted: 0} = VerificationCleanupWorker.sweep(later)
    end
  end

  test "no business detail or storage key reaches the logs", ctx do
    log =
      capture_log([level: :debug], fn ->
        view = submitted!(ctx.owner, ctx.gym.id)
        {:ok, _} = decide(view, :approved)
      end)

    for secret <- ["0000123456", "Ząbkowska", "registry-extract.pdf", "business-verification/"] do
      refute log =~ secret
    end
  end
end
