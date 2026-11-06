defmodule SimpleFit.GymVerificationAuthorityTest do
  @moduledoc """
  SF-136 (SF-104 F-03): nobody reviews gym business verification by naming an
  operator. Every entry point asks the authority; the production gate has no
  configuration; attribution is an immutable actor id; and the database refuses the
  old kind of attribution while keeping old rows as they were.
  """

  # Not async: changes the fixture authority's operators.
  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers
  import SimpleFit.VerificationHelpers

  alias SimpleFit.Gyms.{
    AuditEvent,
    OperatorPrincipal,
    Verification,
    VerificationApplication,
    VerificationAuthority,
    VerificationEvent,
    VerificationReview
  }

  alias SimpleFit.Gyms.VerificationAuthority.{Disabled, Local}
  alias SimpleFit.Repo

  setup do
    Repo.delete_all("rate_limit_events")
    stub_storage(%{})
    owner = registered!("kyb-authority")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, view: submitted!(owner, gym.id)}
  end

  defp status(view), do: Repo.get!(VerificationApplication, view.application.id).status

  defp operator_rows(view) do
    Repo.all(
      from(e in VerificationEvent,
        where: e.application_id == ^view.application.id and e.event != :submitted
      )
    )
  end

  # Every privileged entry point, with `credential` as what the caller presents.
  defp attempts(view, credential) do
    id = view.application.id
    revision = view.application.revision
    [evidence] = view.evidence

    [
      list: fn -> VerificationReview.list_submitted(credential) end,
      show: fn -> VerificationReview.show(id, credential) end,
      document: fn -> VerificationReview.evidence_download(id, evidence.id, credential) end,
      approve: fn ->
        VerificationReview.decide(id, :approved, revision: revision, credential: credential)
      end,
      changes: fn ->
        VerificationReview.decide(id, :changes_requested,
          revision: revision,
          reason: "other",
          credential: credential
        )
      end,
      reject: fn ->
        VerificationReview.decide(id, :rejected,
          revision: revision,
          reason: "other",
          credential: credential
        )
      end,
      revoke: fn -> VerificationReview.revoke(id, reason: "other", credential: credential) end
    ]
  end

  defp assert_all_refused(view, credential, expected) do
    for {name, attempt} <- attempts(view, credential) do
      assert {^name, {:error, ^expected}} = {name, attempt.()}
    end

    assert status(view) == :submitted
    assert operator_rows(view) == []
  end

  describe "impersonation" do
    test "an allowlisted-looking email is not a credential, anywhere", ctx do
      assert_all_refused(ctx.view, "reviewer@trust.simplefit.test", :unauthenticated)
    end

    test "naming an operator in the options changes nothing", ctx do
      assert {:error, :unauthenticated} =
               VerificationReview.decide(ctx.view.application.id, :approved,
                 revision: ctx.view.application.revision,
                 operator: "reviewer@trust.simplefit.test"
               )

      assert {:error, :unauthenticated} =
               VerificationReview.revoke(ctx.view.application.id,
                 reason: "other",
                 operator: "reviewer@trust.simplefit.test"
               )

      assert status(ctx.view) == :submitted
    end

    test "a forged actor id, a hand-built principal or a user are not credentials", ctx do
      forged = %OperatorPrincipal{
        actor_id: reviewer_actor_id(),
        user_id: Ecto.UUID.generate(),
        authority: :local_fixture
      }

      for credential <- [
            reviewer_actor_id(),
            forged,
            %{actor_id: reviewer_actor_id()},
            ctx.owner,
            %{secret: "fixture-reviewer"},
            nil
          ] do
        assert_all_refused(ctx.view, credential, :unauthenticated)
      end
    end

    test "a wrong secret is refused the same as no credential", ctx do
      assert_all_refused(ctx.view, %Local.Credential{secret: "guess"}, :unauthenticated)
    end

    test "an expired credential stops working", ctx do
      credential =
        fixture_operator!(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})

      assert_all_refused(ctx.view, credential, :unauthenticated)
    end

    test "attribution comes from the authority, never from what the caller says", ctx do
      assert {:ok, _} =
               VerificationReview.decide(ctx.view.application.id, :approved,
                 revision: ctx.view.application.revision,
                 credential: operator(),
                 operator: "someone.else@example.com",
                 actor_id: Ecto.UUID.generate()
               )

      assert [row] = operator_rows(ctx.view)
      assert row.operator_actor_id == reviewer_actor_id()
      assert row.operator == nil
    end
  end

  describe "permissions and revocation" do
    test "least privilege: each action needs its own permission", ctx do
      id = ctx.view.application.id
      revision = ctx.view.application.revision

      reader = fixture_operator!(%{permissions: [:read_queue, :read_application]})
      assert {:ok, _} = VerificationReview.show(id, reader)

      assert {:error, {:forbidden, :operator}} =
               VerificationReview.decide(id, :approved, revision: revision, credential: reader)

      assert {:error, {:forbidden, :operator}} =
               VerificationReview.evidence_download(id, hd(ctx.view.evidence).id, reader)

      rejecter = fixture_operator!(%{permissions: [:reject]})

      assert {:error, {:forbidden, :operator}} =
               VerificationReview.decide(id, :approved, revision: revision, credential: rejecter)

      assert {:error, {:forbidden, :operator}} =
               VerificationReview.show(id, rejecter)

      assert {:ok, _} =
               VerificationReview.decide(id, :rejected,
                 revision: revision,
                 reason: "other",
                 credential: rejecter
               )
    end

    test "a revoked operator is refused on the next call; their history stays", ctx do
      credential = fixture_operator!(%{})
      assert {:ok, _} = VerificationReview.show(ctx.view.application.id, credential)

      assert {:ok, _} =
               VerificationReview.evidence_download(
                 ctx.view.application.id,
                 hd(ctx.view.evidence).id,
                 credential
               )

      before = operator_rows(ctx.view)
      revoke_operator(credential)

      for {name, attempt} <- attempts(ctx.view, credential) do
        assert {^name, {:error, {:forbidden, :operator}}} = {name, attempt.()}
      end

      assert status(ctx.view) == :submitted
      assert operator_rows(ctx.view) == before
    end

    test "gym roles grant nothing: an owner's or manager's session is no credential", ctx do
      {manager, _} = joined_staff!(ctx.owner, ctx.gym.id, :manager, "Mia Manager")

      for person <- [ctx.owner, manager] do
        assert_all_refused(ctx.view, live_session!(person), :unauthenticated)
      end
    end
  end

  describe "the production gate" do
    test "the disabled authority refuses everything, whatever is presented", _ctx do
      refute Disabled.available?()
      assert Disabled.ambient_credential() == nil

      for credential <- [operator(), "reviewer@trust.simplefit.test", nil, %{}] do
        for permission <-
              ~w(read_queue read_application read_evidence approve request_changes reject revoke)a do
          assert Disabled.authenticate(credential, permission) == {:error, :review_disabled}
        end
      end
    end

    test "the authority is fixed at compile time: runtime configuration can't change it", ctx do
      original = Application.get_env(:simple_fit, VerificationAuthority)
      on_exit(fn -> Application.put_env(:simple_fit, VerificationAuthority, original) end)
      Application.put_env(:simple_fit, VerificationAuthority, backend: Disabled)

      # Still the build's own backend: a setting read at runtime would have refused.
      assert {:ok, _} = VerificationAuthority.authenticate(operator(), :read_queue)
      assert VerificationAuthority.available?()
      assert status(ctx.view) == :submitted
    end

    test "the source guards production: the build refuses another backend, and has no fixture" do
      authority = File.read!("lib/simple_fit/gyms/verification_authority.ex")
      local = File.read!("lib/simple_fit/gyms/verification_authority/local.ex")

      assert authority =~ "if Mix.env() == :prod and @backend !="
      assert local =~ ~r/^if Mix.env\(\) != :prod do$/m

      runtime = File.read!("config/runtime.exs")
      refute runtime =~ "VerificationAuthority"
      refute runtime =~ "GYM_VERIFICATION_OPERATORS"
      refute File.read!("config/prod.exs") =~ "VerificationAuthority"
      refute File.read!("config/config.exs") =~ "VerificationAuthority"
    end

    test "no HTTP route reaches review" do
      refute File.read!("lib/simple_fit_web/router.ex") =~ "VerificationReview"

      for path <- Path.wildcard("lib/simple_fit_web/**/*.ex") do
        refute File.read!(path) =~ "VerificationReview", path
      end
    end
  end

  describe "the single boundary" do
    test "only the review module writes a decision, and a decision's trail is whole", ctx do
      callers =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ "VerificationReview."))
        |> Enum.reject(&String.ends_with?(&1, "verification_review.ex"))

      assert callers == ["lib/mix/tasks/gyms.verification.ex"]

      assert {:ok, _} =
               VerificationReview.decide(ctx.view.application.id, :approved,
                 revision: ctx.view.application.revision,
                 credential: operator()
               )

      assert [row] = operator_rows(ctx.view)
      assert {:operator, actor, :local_fixture} = VerificationEvent.attribution(row)
      assert actor == reviewer_actor_id()
      assert is_binary(row.operation_id)

      assert Repo.exists?(
               from(e in AuditEvent,
                 where:
                   e.verification_application_id == ^ctx.view.application.id and
                     e.event_type == :business_verification_approved
               )
             )
    end

    test "a failure on the trail undoes the decision: no decision without its history", ctx do
      id = ctx.view.application.id

      # The shape of `commit`, with a history row the database refuses.
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn ->
          application = Repo.get!(VerificationApplication, id)

          application
          |> Ecto.Changeset.change(status: :approved, decided_at: DateTime.utc_now())
          |> Repo.update!()

          Verification.record_event!(
            application,
            :approved,
            %{operator: "a@b.co"},
            DateTime.utc_now()
          )
        end)
      end

      assert status(ctx.view) == :submitted
    end
  end

  describe "the database" do
    test "new rows can't use an email, or lack the actor, authority or operation", ctx do
      base = %{
        gym_id: ctx.gym.id,
        application_id: ctx.view.application.id,
        event: :approved,
        application_revision: ctx.view.application.revision,
        evidence_ids: [],
        occurred_at: DateTime.utc_now()
      }

      for attrs <- [
            %{operator: "reviewer@trust.simplefit.test"},
            %{operator_actor_id: Ecto.UUID.generate()},
            %{operator_authority: :local_fixture},
            %{operator_actor_id: Ecto.UUID.generate(), operator_authority: :local_fixture},
            %{
              operator: "a@b.co",
              operator_actor_id: Ecto.UUID.generate(),
              operator_authority: :local_fixture,
              operation_id: Ecto.UUID.generate()
            }
          ] do
        assert_raise Ecto.ConstraintError, fn ->
          Repo.transaction(fn ->
            Repo.insert!(struct!(VerificationEvent, Map.merge(base, attrs)))
          end)
        end
      end
    end

    test "an unknown authority is refused by the database, and the constraint stays NOT VALID",
         ctx do
      assert {:error,
              %Postgrex.Error{
                postgres: %{constraint: "operator_authority_values"}
              }} =
               Repo.query(
                 """
                 INSERT INTO gym_verification_events
                   (id, gym_id, application_id, event, application_revision, evidence_ids,
                    operator_actor_id, operator_authority, operation_id, occurred_at)
                 VALUES (gen_random_uuid(), $1, $2, 'approved', 1, '{}', gen_random_uuid(),
                   'allowlisted_email', gen_random_uuid(), now())
                 """,
                 [Ecto.UUID.dump!(ctx.gym.id), Ecto.UUID.dump!(ctx.view.application.id)]
               )

      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT convalidated FROM pg_constraint WHERE conname = 'gym_verification_events_trusted_actor'"
               )
    end

    test "a legacy row is labelled as what it is" do
      assert VerificationEvent.attribution(%VerificationEvent{operator: "a@b.co"}) ==
               {:legacy_unverified, "a@b.co"}
    end
  end
end
