defmodule SimpleFit.SponsorApplicationEvidenceTest do
  @moduledoc """
  SF-114 in the SQL sandbox: application evidence (presign, HEAD verification,
  removal, freezing, cleanup), contact email verification, the notification outbox
  and marketing consent independence. Operator review is in
  `SimpleFit.SponsorApplicationReviewTest`; HTTP in the controller tests.
  """

  use SimpleFit.DataCase, async: false
  use Oban.Testing, repo: SimpleFit.Repo

  import ExUnit.CaptureLog
  import SimpleFit.SponsorApplicationHelpers
  import SimpleFit.VerificationHelpers, only: [stub_storage: 1]
  import SimpleFit.GymHelpers, only: [registered!: 1, email_user!: 1]

  alias SimpleFit.Accounts.Consents
  alias SimpleFit.Email.{DeliveryWorker, JobPayload}
  alias SimpleFit.Sponsors

  alias SimpleFit.Sponsors.{
    ApplicationContactCode,
    ApplicationEvidence,
    ApplicationNotification,
    Applications,
    ApplicationSubmission,
    ContactVerification,
    Evidence,
    EvidenceCleanupWorker,
    Membership,
    Organization
  }

  @pdf %{
    "kind" => "brand_deck",
    "file_name" => "Acme deck.pdf",
    "content_type" => "application/pdf",
    "byte_size" => 2048
  }

  setup do
    email = "applicant-#{System.unique_integer([:positive])}@example.com"
    user = email_user!(email)
    %{user: user, email: email, app: draft!(user)}
  end

  defp put_sponsors_env(key, value) do
    config = Elixir.Application.get_env(:simple_fit, Sponsors)
    Elixir.Application.put_env(:simple_fit, Sponsors, Keyword.put(config, key, value))
    on_exit(fn -> Elixir.Application.put_env(:simple_fit, Sponsors, config) end)
  end

  defp revision(app), do: Repo.reload!(app).revision

  defp initiate!(user, app, overrides \\ %{}) do
    params = Map.merge(@pdf, %{"expected_revision" => revision(app)}) |> Map.merge(overrides)
    {:ok, {_view, evidence, upload}} = Evidence.initiate(user, params)
    {evidence, upload}
  end

  defp uploaded!(user, app, overrides \\ %{}) do
    {evidence, _} = initiate!(user, app, overrides)
    stub_storage(%{evidence.id => {evidence.byte_size, evidence.content_type}})
    {:ok, _} = Evidence.confirm(user, evidence.id)
    Repo.reload!(evidence)
  end

  defp notifications(app_id),
    do:
      Repo.all(
        from(n in ApplicationNotification,
          where: n.application_id == ^app_id,
          order_by: [n.inserted_at, n.id]
        )
      )

  # The text of the newest queued email.
  defp last_email_text do
    job = Repo.one!(from(j in Oban.Job, order_by: [desc: j.id], limit: 1))
    {:ok, message} = JobPayload.open(job.args["payload"])
    message
  end

  describe "initiating an upload" do
    test "the owner gets a presigned PUT for a server-built key; a row is pending", c do
      {evidence, upload} = initiate!(c.user, c.app)

      assert evidence.status == :pending_upload
      assert evidence.object_key == "sponsors/applications/#{c.app.id}/evidence/#{evidence.id}"
      assert upload.method == :put
      assert upload.headers["content-type"] == "application/pdf"
      assert DateTime.diff(upload.expires_at, DateTime.utc_now()) in 880..900
      # The application changed (its revision moved).
      assert revision(c.app) > c.app.revision
    end

    test "nothing but the owner's current editable application", c do
      stranger = registered!("stranger")

      assert {:error, :not_found} =
               Evidence.initiate(stranger, Map.put(@pdf, "expected_revision", 1))

      assert {:error, {:revision_conflict, _}} =
               Evidence.initiate(c.user, Map.put(@pdf, "expected_revision", revision(c.app) + 1))

      submitted = submitted!(c.user, c.app)

      assert {:error, {:conflict, %{application: "not_editable"}}} =
               Evidence.initiate(c.user, Map.put(@pdf, "expected_revision", submitted.revision))
    end

    test "the policy: type, size, name, kind, unknown fields, five live documents", c do
      rev = revision(c.app)

      for {field, value} <- [
            {"content_type", "application/zip"},
            {"content_type", "image/svg+xml"},
            {"byte_size", 10 * 1024 * 1024 + 1},
            {"byte_size", 0},
            {"file_name", "../../etc/passwd"},
            {"file_name", String.duplicate("a", 121)},
            {"kind", "passport"}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Evidence.initiate(
                   c.user,
                   @pdf |> Map.put(field, value) |> Map.put("expected_revision", rev)
                 ),
               "#{field}=#{inspect(value)}"
      end

      # No client key, bucket or URL is accepted.
      assert {:error, %Ecto.Changeset{} = cs} =
               Evidence.initiate(
                 c.user,
                 Map.merge(@pdf, %{"expected_revision" => rev, "object_key" => "elsewhere/x"})
               )

      refute cs.valid?

      for _ <- 1..5, do: initiate!(c.user, c.app)

      assert {:error, {:conflict, %{evidence: "limit_reached"}}} =
               Evidence.initiate(c.user, Map.put(@pdf, "expected_revision", revision(c.app)))
    end

    test "unavailable where uploads are off (production until D-SA09)", c do
      put_sponsors_env(:evidence_uploads, false)

      assert {:error, :service_unavailable} =
               Evidence.initiate(c.user, Map.put(@pdf, "expected_revision", revision(c.app)))

      assert Evidence.policy().available == false
      assert Applications.view(Repo.reload!(c.app)).evidence == []
    end
  end

  describe "confirming an upload" do
    test "attaches only the object storage reports with the allowed size and type", c do
      {evidence, _} = initiate!(c.user, c.app)
      stub_storage(%{evidence.id => {2048, "application/pdf"}})

      assert {:ok, view} = Evidence.confirm(c.user, evidence.id)
      assert [%{status: :uploaded, uploaded_at: %DateTime{}}] = view.evidence

      # Again: the same answer, no storage call needed, nothing changes.
      Req.Test.stub(SimpleFit.Storage, fn _ -> flunk("no storage call expected") end)
      rev = revision(c.app)
      assert {:ok, _} = Evidence.confirm(c.user, evidence.id)
      assert revision(c.app) == rev
    end

    test "a missing, resized or retyped object attaches nothing", c do
      {evidence, _} = initiate!(c.user, c.app)

      stub_storage(%{})
      assert {:error, {:conflict, %{upload: "not_found"}}} = Evidence.confirm(c.user, evidence.id)

      stub_storage(%{evidence.id => {4096, "application/pdf"}})
      assert {:error, {:conflict, %{upload: "mismatch"}}} = Evidence.confirm(c.user, evidence.id)

      stub_storage(%{evidence.id => {2048, "text/html"}})
      assert {:error, {:conflict, %{upload: "mismatch"}}} = Evidence.confirm(c.user, evidence.id)

      assert Repo.reload!(evidence).status == :pending_upload

      # A parameterised type is fine.
      stub_storage(%{evidence.id => {2048, "application/pdf; charset=binary"}})
      assert {:ok, _} = Evidence.confirm(c.user, evidence.id)
    end

    test "after the upload window and its grace, the upload is expired", c do
      {evidence, _} = initiate!(c.user, c.app)
      past = DateTime.add(DateTime.utc_now(), -3700)

      Repo.update_all(from(e in ApplicationEvidence, where: e.id == ^evidence.id),
        set: [upload_expires_at: past]
      )

      stub_storage(%{evidence.id => {2048, "application/pdf"}})
      assert {:error, {:conflict, %{upload: "expired"}}} = Evidence.confirm(c.user, evidence.id)
    end

    test "only the owner's evidence: anyone else's id is not found", c do
      {evidence, _} = initiate!(c.user, c.app)
      stranger = registered!("stranger")
      _other = draft!(stranger)
      stub_storage(%{evidence.id => {2048, "application/pdf"}})

      assert {:error, :not_found} = Evidence.confirm(stranger, evidence.id)
      assert {:error, :not_found} = Evidence.confirm(c.user, Ecto.UUID.generate())
      assert {:error, :not_found} = Evidence.confirm(c.user, "not-a-uuid")
      assert Repo.reload!(evidence).status == :pending_upload
    end

    test "a storage failure is unavailable and changes nothing", c do
      {evidence, _} = initiate!(c.user, c.app)
      Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, 503, ""))

      assert {:error, :service_unavailable} = Evidence.confirm(c.user, evidence.id)
      assert Repo.reload!(evidence).status == :pending_upload
    end

    test "a removed document can't be confirmed", c do
      {evidence, _} = initiate!(c.user, c.app)
      {:ok, _} = Evidence.remove(c.user, evidence.id, %{"expected_revision" => revision(c.app)})

      assert {:error, {:conflict, %{evidence: "removed"}}} = Evidence.confirm(c.user, evidence.id)
    end

    test "logs carry no key, presigned URL, signature or file name", c do
      log =
        capture_log([level: :debug], fn ->
          {evidence, upload} = initiate!(c.user, c.app)
          stub_storage(%{evidence.id => {2048, "application/pdf"}})
          {:ok, _} = Evidence.confirm(c.user, evidence.id)
          send(self(), {:seen, evidence, upload})
        end)

      assert_received {:seen, evidence, upload}
      refute log =~ evidence.object_key
      refute log =~ upload.url
      refute log =~ "X-Amz-Signature"
      refute log =~ "Acme deck"
    end
  end

  describe "removing and submitting" do
    test "a document can be removed (idempotently) until it is submitted, then it is frozen",
         c do
      removable = uploaded!(c.user, c.app)
      {:ok, _} = Evidence.remove(c.user, removable.id, %{"expected_revision" => revision(c.app)})

      assert {:ok, _} =
               Evidence.remove(c.user, removable.id, %{"expected_revision" => revision(c.app)})

      assert %{status: :removed, removed_reason: "owner"} = Repo.reload!(removable)

      kept = uploaded!(c.user, c.app)
      {pending, _} = initiate!(c.user, c.app)
      app = submitted!(c.user, Repo.reload!(c.app))

      submission = Repo.one!(from(s in ApplicationSubmission, where: s.application_id == ^app.id))

      # The snapshot names only the attached document, without key or file name.
      assert [
               %{
                 "evidence_id" => kept_id,
                 "kind" => "brand_deck",
                 "content_type" => "application/pdf",
                 "byte_size" => 2048,
                 "scanned" => false
               }
             ] = submission.snapshot["uploads"]

      assert kept_id == kept.id
      refute inspect(submission.snapshot) =~ kept.object_key
      assert Repo.reload!(kept).submission_id == submission.id
      assert Repo.reload!(pending).submission_id == nil

      # Frozen in the database too, not only by the domain.
      assert_raise Postgrex.Error, ~r/frozen/, fn ->
        Repo.update_all(from(e in ApplicationEvidence, where: e.id == ^kept.id),
          set: [status: :removed, removed_at: DateTime.utc_now(), removed_reason: "owner"]
        )
      end
    end

    test "evidence rows are never deleted and their identity never changes", c do
      evidence = uploaded!(c.user, c.app)

      assert_raise Postgrex.Error, ~r/never deleted/, fn ->
        Repo.delete_all(from(e in ApplicationEvidence, where: e.id == ^evidence.id))
      end

      assert_raise Postgrex.Error, ~r/immutable/, fn ->
        Repo.update_all(from(e in ApplicationEvidence, where: e.id == ^evidence.id),
          set: [byte_size: 1]
        )
      end
    end

    test "a submitted document stays attached after changes are requested and is never removable",
         c do
      evidence = uploaded!(c.user, c.app)
      app = submitted!(c.user, Repo.reload!(c.app))
      app = app |> review!(:under_review) |> review!(:changes_requested)

      assert {:error, {:conflict, %{evidence: "submitted"}}} =
               Evidence.remove(c.user, evidence.id, %{"expected_revision" => app.revision})

      # A resubmission keeps it on its first submission.
      {:ok, _} = Applications.submit(c.user, submit_params(app))
      first = Repo.reload!(evidence).submission_id

      assert Repo.one!(
               from(s in ApplicationSubmission,
                 where: s.application_id == ^app.id and s.sequence == 1,
                 select: s.id
               )
             ) == first
    end
  end

  describe "cleanup" do
    test "abandons stale uploads and deletes objects of removed, never-submitted documents only",
         c do
      {stale, _} = initiate!(c.user, c.app)
      {fresh, _} = initiate!(c.user, c.app)
      removed = uploaded!(c.user, c.app)
      {:ok, _} = Evidence.remove(c.user, removed.id, %{"expected_revision" => revision(c.app)})
      submitted = uploaded!(c.user, c.app)
      _ = submitted!(c.user, Repo.reload!(c.app))

      Repo.update_all(from(e in ApplicationEvidence, where: e.id == ^stale.id),
        set: [upload_expires_at: DateTime.add(DateTime.utc_now(), -(25 * 3600))]
      )

      stub_storage(%{})
      assert :ok = perform_job(EvidenceCleanupWorker, %{})

      assert %{status: :removed, removed_reason: "abandoned", object_deleted_at: %DateTime{}} =
               Repo.reload!(stale)

      assert %{status: :pending_upload, object_deleted_at: nil} = Repo.reload!(fresh)
      assert %{object_deleted_at: %DateTime{}} = Repo.reload!(removed)
      assert %{status: :uploaded, object_deleted_at: nil} = Repo.reload!(submitted)

      deleted =
        for _ <- 1..2 do
          assert_received {:storage_deleted, path}
          path
        end

      for e <- [stale, removed],
          do: assert(Enum.any?(deleted, &String.ends_with?(&1, "/" <> e.object_key)))

      refute_received {:storage_deleted, _}

      # Idempotent.
      assert :ok = perform_job(EvidenceCleanupWorker, %{})
      refute_received {:storage_deleted, _}
    end

    test "a storage failure leaves the object to the next run", c do
      removed = uploaded!(c.user, c.app)
      {:ok, _} = Evidence.remove(c.user, removed.id, %{"expected_revision" => revision(c.app)})
      Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, 503, ""))

      capture_log(fn -> perform_job(EvidenceCleanupWorker, %{}) end)
      assert Repo.reload!(removed).object_deleted_at == nil
    end
  end

  describe "notifications" do
    test "submission records one intent and queues one encrypted email to the applicant", c do
      app = submitted!(c.user, c.app)

      assert [%{kind: :application_received, recipient: :applicant, status: :queued} = n] =
               notifications(app.id)

      assert_enqueued(worker: DeliveryWorker, queue: :mailers)
      job = Repo.get!(Oban.Job, n.oban_job_id)
      assert Map.keys(job.args) == ["payload"]
      refute inspect(job.args) =~ c.email
      refute inspect(job.args) =~ "Acme"

      message = last_email_text()
      assert message.to == [c.email]
      # Received, not approved: nothing promises an outcome.
      refute message.text =~ ~r/approved/i
    end

    test "a resubmission says so; the dedupe key is per submission", c do
      app = submitted!(c.user, c.app) |> review!(:under_review) |> review!(:changes_requested)
      {:ok, _} = Applications.submit(c.user, submit_params(app))

      assert [:application_received, :application_resubmitted] =
               Enum.map(notifications(app.id), & &1.kind)
    end

    test "a rolled-back change records and queues nothing", c do
      Repo.transaction(fn ->
        {:ok, _} = Applications.submit(c.user, submit_params(c.app))
        Repo.rollback(:test)
      end)

      assert notifications(c.app.id) == []
      refute_enqueued(worker: DeliveryWorker)
    end

    test "disabled sending records a suppressed intent and queues nothing", c do
      put_sponsors_env(:application_emails, false)
      app = submitted!(c.user, c.app)

      assert [%{status: :suppressed, suppressed_reason: "delivery_disabled", oban_job_id: nil}] =
               notifications(app.id)

      refute_enqueued(worker: DeliveryWorker)
    end

    test "the outbox is append-only", c do
      app = submitted!(c.user, c.app)
      [n] = notifications(app.id)

      assert_raise Postgrex.Error, fn ->
        Repo.delete_all(from(x in ApplicationNotification, where: x.id == ^n.id))
      end
    end
  end

  describe "contact email verification" do
    test "a code sent to the contact email verifies it, once, for that address only", c do
      assert {:ok, view} = ContactVerification.request(c.user)
      refute view.contact_email_verified

      message = last_email_text()
      assert message.to == ["ada@acme.example"]
      [code] = Regex.run(~r/\b\d{6}\b/, message.text)

      # Only a keyed verifier and an address digest are stored.
      row = Repo.one!(from(x in ApplicationContactCode, where: x.application_id == ^c.app.id))
      refute inspect(Map.from_struct(row)) =~ code
      refute inspect(Map.from_struct(row)) =~ "ada@acme.example"

      assert {:ok, view} = ContactVerification.confirm(c.user, %{"code" => code})
      assert view.contact_email_verified

      # Replay: the code is used.
      assert {:error, :code_expired} = ContactVerification.confirm(c.user, %{"code" => code})

      # Changing the address unverifies it.
      {:ok, view} =
        Applications.save(c.user, %{
          "expected_revision" => revision(c.app),
          "contact_email" => "other@acme.example"
        })

      refute view.contact_email_verified

      # A verified submission says so in its snapshot.
      {:ok, _} = ContactVerification.request(c.user)
      [code] = Regex.run(~r/\b\d{6}\b/, last_email_text().text)
      {:ok, _} = ContactVerification.confirm(c.user, %{"code" => code})
      app = submitted!(c.user, Repo.reload!(c.app))
      submission = Repo.one!(from(s in ApplicationSubmission, where: s.application_id == ^app.id))
      assert submission.snapshot["contact_email_verified"] == true
    end

    test "a wrong code counts; five wrong codes use it up", c do
      {:ok, _} = ContactVerification.request(c.user)
      [code] = Regex.run(~r/\b\d{6}\b/, last_email_text().text)
      wrong = if code == "000000", do: "111111", else: "000000"

      for _ <- 1..5,
          do:
            assert(
              {:error, :code_invalid} = ContactVerification.confirm(c.user, %{"code" => wrong})
            )

      assert {:error, :code_expired} = ContactVerification.confirm(c.user, %{"code" => code})

      assert {:error, %Ecto.Changeset{}} =
               ContactVerification.confirm(c.user, %{"code" => "12ab"})
    end

    test "an expired code or a code sent to an earlier address is refused", c do
      {:ok, _} = ContactVerification.request(c.user)
      [code] = Regex.run(~r/\b\d{6}\b/, last_email_text().text)

      Repo.update_all(from(x in ApplicationContactCode, where: x.application_id == ^c.app.id),
        set: [
          inserted_at: DateTime.add(DateTime.utc_now(), -1000),
          expires_at: DateTime.add(DateTime.utc_now(), -1)
        ]
      )

      assert {:error, :code_expired} = ContactVerification.confirm(c.user, %{"code" => code})

      {:ok, _} = ContactVerification.request(c.user)
      [code] = Regex.run(~r/\b\d{6}\b/, last_email_text().text)

      {:ok, _} =
        Applications.save(c.user, %{
          "expected_revision" => revision(c.app),
          "contact_email" => "other@acme.example"
        })

      assert {:error, :code_expired} = ContactVerification.confirm(c.user, %{"code" => code})
    end

    test "a new code supersedes the previous one", c do
      {:ok, _} = ContactVerification.request(c.user)
      [first] = Regex.run(~r/\b\d{6}\b/, last_email_text().text)
      {:ok, _} = ContactVerification.request(c.user)
      [second] = Regex.run(~r/\b\d{6}\b/, last_email_text().text)

      # The first code is no longer the live one: it is simply wrong now.
      if first != second,
        do:
          assert(
            {:error, :code_invalid} = ContactVerification.confirm(c.user, %{"code" => first})
          )

      assert {:ok, _} = ContactVerification.confirm(c.user, %{"code" => second})
    end

    test "throttled per application", c do
      for _ <- 1..3, do: {:ok, _} = ContactVerification.request(c.user)
      assert {:error, {:rate_limited, _}} = ContactVerification.request(c.user)
    end

    test "verification grants nothing: no organization, membership or account", c do
      {:ok, _} = ContactVerification.request(c.user)
      [code] = Regex.run(~r/\b\d{6}\b/, last_email_text().text)
      users = Repo.aggregate(SimpleFit.Accounts.User, :count)
      {:ok, _} = ContactVerification.confirm(c.user, %{"code" => code})

      assert Repo.aggregate(Organization, :count) == 0
      assert Repo.aggregate(Membership, :count) == 0
      assert Repo.aggregate(SimpleFit.Accounts.User, :count) == users
    end

    test "unavailable without email sending; no contact email is a conflict", c do
      put_sponsors_env(:application_emails, false)
      assert {:error, :service_unavailable} = ContactVerification.request(c.user)

      assert {:error, :service_unavailable} =
               ContactVerification.confirm(c.user, %{"code" => "123456"})

      put_sponsors_env(:application_emails, true)
      other = registered!("no-contact")
      _ = draft!(other, %{"company_name" => "Nameless"})

      assert {:error, {:conflict, %{contact_email: "missing"}}} =
               ContactVerification.request(other)
    end
  end

  describe "consent" do
    test "submitting records the legal declaration and never touches marketing consent", c do
      before = Consents.state(c.user.id).product_news
      app = submitted!(c.user, c.app)
      submission = Repo.one!(from(s in ApplicationSubmission, where: s.application_id == ^app.id))

      assert Consents.state(c.user.id).product_news == before
      assert submission.declaration_version == "sponsor-application-declaration-test-1"
      refute Map.has_key?(submission.snapshot, "product_news")
      refute Map.has_key?(submission.snapshot, "marketing")
    end
  end
end
