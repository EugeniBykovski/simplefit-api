defmodule SimpleFit.GymMembersCloseoutTest do
  @moduledoc """
  SF-95 release-readiness invariants: the E07 launch gate, independence of
  gym memberships from other gyms, staff and coaching, the account-deletion
  interaction, join-code generation, enumeration and leak resistance, the
  CSV boundary (no hidden commit) and the `invite_members` milestone.
  Not async: one test switches the member-invitation gate.
  """

  use SimpleFit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import SimpleFit.GymHelpers

  alias SimpleFit.{Accounts, Gyms, Repo}
  alias SimpleFit.Accounts.User

  alias SimpleFit.Gyms.{
    Member,
    MemberInvitation,
    MemberInvitations,
    MemberSecrets,
    StaffMembership
  }

  setup do
    owner = registered_as!(registered!("closeout"), "Yauheni Bykovski")
    gym = completed_gym!(owner)
    %{owner: owner, gym: gym, code: join_code!(owner, gym.id)}
  end

  defp count(query), do: Repo.aggregate(query, :count)

  describe "E07 launch gate" do
    setup do
      previous = Application.get_env(:simple_fit, SimpleFit.Gyms)
      on_exit(fn -> Application.put_env(:simple_fit, SimpleFit.Gyms, previous) end)
      %{previous: previous}
    end

    test "off: creation and resend refuse after access checks; nothing is stored or queued",
         ctx do
      invitation = invite_member!(ctx.owner, ctx.gym.id, address("before-gate"))
      jobs = count(Oban.Job)

      Application.put_env(
        :simple_fit,
        SimpleFit.Gyms,
        Keyword.put(ctx.previous, :member_invitations, false)
      )

      refute MemberInvitations.delivery_enabled?()

      assert {:error, {:conflict, %{member_invitation: "recipient_flow_unavailable"}}} =
               Gyms.create_member_invitation(
                 ctx.owner,
                 ctx.gym.id,
                 %{"email" => address()},
                 client_ip()
               )

      assert {:error, {:conflict, %{member_invitation: "recipient_flow_unavailable"}}} =
               Gyms.resend_member_invitation(ctx.owner, ctx.gym.id, invitation.invitation_id)

      # Outsiders still learn nothing about the gym.
      assert {:error, :not_found} =
               Gyms.create_member_invitation(
                 registered!("o"),
                 ctx.gym.id,
                 %{"email" => address()},
                 client_ip()
               )

      assert count(from(i in MemberInvitation, where: i.gym_id == ^ctx.gym.id)) == 1
      assert count(Oban.Job) == jobs

      # Existing invitations can still be cancelled.
      assert {:ok, %{status: :cancelled}} =
               Gyms.cancel_member_invitation(ctx.owner, ctx.gym.id, invitation.invitation_id)
    end

    test "off over HTTP: 409 recipient_flow_unavailable", ctx do
      Application.put_env(
        :simple_fit,
        SimpleFit.Gyms,
        Keyword.put(ctx.previous, :member_invitations, false)
      )

      {:ok, credentials} = Accounts.create_session(ctx.owner)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> credentials.access_token)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(
          SimpleFitWeb.Endpoint,
          :post,
          "/api/v1/gyms/#{ctx.gym.id}/member-invitations",
          Jason.encode!(%{email: address()})
        )

      assert %{
               "error" => %{
                 "code" => "conflict",
                 "details" => %{"member_invitation" => "recipient_flow_unavailable"}
               }
             } =
               Phoenix.ConnTest.json_response(conn, 409)
    end

    test "fail closed: anything but true is off", ctx do
      for value <- [nil, "true", "enabled", 1] do
        Application.put_env(
          :simple_fit,
          SimpleFit.Gyms,
          Keyword.put(ctx.previous, :member_invitations, value)
        )

        refute MemberInvitations.delivery_enabled?(), inspect(value)
      end
    end
  end

  describe "membership independence" do
    test "Gym A and Gym B memberships are independent", ctx do
      other_owner = registered!("gym-b")
      gym_b = completed_gym!(other_owner)
      code_b = join_code!(other_owner, gym_b.id)
      user = email_user!(address("two-gyms"))
      session = live_session!(user)

      {:ok, a, :created} = Gyms.join_gym(user, session, ctx.code, client_ip())
      {:ok, b, :created} = Gyms.join_gym(user, session, code_b, client_ip())
      {:ok, _} = Gyms.approve_join_request(other_owner, gym_b.id, b.gym_member_id)

      # Staff of one gym see nothing of the other.
      assert {:error, :not_found} = Gyms.get_member(ctx.owner, ctx.gym.id, b.gym_member_id)

      assert {:error, :not_found} =
               Gyms.approve_join_request(ctx.owner, ctx.gym.id, b.gym_member_id)

      {:ok, _} = Gyms.cancel_gym_join_request(user, session, a.gym_member_id)
      assert %Member{status: :active} = stored_member(b.gym_member_id)
      assert %Member{status: :cancelled} = stored_member(a.gym_member_id)
    end

    test "joining, approval and acceptance create no staff membership, profile or relationship",
         ctx do
      email = address("no-side-effects")
      user = email_user!(email)
      staff = count(StaffMembership)
      relationships = count("coach_fighter_relationships")

      {:ok, request, :created} = join(user, ctx.code)
      {:ok, _} = Gyms.approve_join_request(ctx.owner, ctx.gym.id, request.gym_member_id)
      {:ok, _} = Gyms.leave_gym_membership(user, live_session!(user), request.gym_member_id)
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)

      {:ok, _} =
        Gyms.accept_member_invitation(
          user,
          live_session!(user),
          {:id, invitation.invitation_id},
          client_ip()
        )

      assert count(StaffMembership) == staff
      assert count("coach_fighter_relationships") == relationships

      assert count(from(f in "fighter_profiles", where: f.user_id == type(^user.id, :binary_id))) ==
               0

      assert count(from(c in "coach_profiles", where: c.user_id == type(^user.id, :binary_id))) ==
               0

      assert %{total: 0} = Gyms.workspace_overview(user, 5)
    end
  end

  describe "account deletion" do
    test "a current membership blocks deletion; after leaving, deletion keeps the history", ctx do
      {member, view} = active_member!(ctx.owner, ctx.gym.id, ctx.code)
      assert :ok = Gyms.check_account_deletion(member)

      assert_raise Postgrex.Error, ~r/user_present/, fn ->
        Repo.delete_all(from(u in User, where: u.id == ^member.id))
      end

      {:ok, _} = Gyms.leave_gym_membership(member, live_session!(member), view.gym_member_id)
      {1, _} = Repo.delete_all(from(u in User, where: u.id == ^member.id))

      assert %Member{user_id: nil, status: :ended, ended_reason: :left} =
               stored_member(view.gym_member_id)

      assert {:ok, %{entries: [%{name: nil, status: :ended}]}} =
               Gyms.list_members(ctx.owner, ctx.gym.id, %{"status" => "ended"})
    end
  end

  describe "join-code security" do
    test "codes are 8 symbols of the 32-symbol alphabet, unpredictable and unique" do
      alphabet = String.graphemes("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
      codes = for _ <- 1..2_000, do: MemberSecrets.generate_join_code()

      assert Enum.all?(codes, &(String.length(&1) == 8))
      assert Enum.all?(codes, fn code -> Enum.all?(String.graphemes(code), &(&1 in alphabet)) end)
      assert length(Enum.uniq(codes)) == 2_000
      # Every symbol appears (no truncated alphabet).
      assert codes |> Enum.flat_map(&String.graphemes/1) |> Enum.uniq() |> length() == 32
    end

    test "normalization accepts typing variants and rejects everything else without lookups" do
      assert {:ok, "0113ABCD"} = MemberSecrets.normalize_join_code(" o1i3-abcd ")
      assert {:ok, "01111111"} = MemberSecrets.normalize_join_code("OLIL-ilil")

      for bad <- [
            "ABCD-EFGU",
            "ABCDEFG",
            "ABCDEFGHJ",
            "ABCD_EFGH",
            "ąbcd-efgh",
            "",
            nil,
            12_345_678,
            String.duplicate("A", 33)
          ] do
        assert :error == MemberSecrets.normalize_join_code(bad), inspect(bad)
      end
    end

    test "unknown, malformed and disabled codes are indistinguishable", ctx do
      user = email_user!(address("enum"))
      unknown = join(user, "ZZZZ-ZZZZ")
      malformed = join(user, "not a code")
      {:ok, _} = Gyms.disable_join_code(ctx.owner, ctx.gym.id)
      disabled = join(user, ctx.code)

      assert unknown == {:error, :not_found}
      assert malformed == unknown
      assert disabled == unknown
      assert Gyms.preview_gym_join(ctx.code, client_ip()) == {:error, :not_found}
    end

    test "auto-approval never bypasses registration, a disabled code or the staff decision for others",
         ctx do
      auto_approve!(ctx.owner, ctx.gym.id, true)
      {:ok, unregistered} = Accounts.register_user(:email, address("unreg-auto"))
      assert {:error, %Ecto.Changeset{}} = join(unregistered, ctx.code)
      assert member_rows(ctx.gym.id, unregistered) == []

      {:ok, _} = Gyms.disable_join_code(ctx.owner, ctx.gym.id)
      assert {:error, :not_found} = join(email_user!(address("late-auto")), ctx.code)
    end

    test "the per-client limit holds across accounts, counting failed guesses", ctx do
      ip = client_ip()

      for _ <- 1..20 do
        guesser = email_user!(address("guess"))
        Gyms.join_gym(guesser, live_session!(guesser), MemberSecrets.generate_join_code(), ip)
      end

      fresh = email_user!(address("fresh"))

      assert {:error, {:rate_limited, _}} =
               Gyms.join_gym(fresh, live_session!(fresh), ctx.code, ip)

      assert member_rows(ctx.gym.id, fresh) == []
    end

    test "telemetry carries outcomes only, never the code or ids", ctx do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "closeout-#{inspect(ref)}",
        [[:simple_fit, :gyms, :member, :joined], [:simple_fit, :gyms, :member, :join_previewed]],
        fn event, _measurements, metadata, _ -> send(parent, {ref, event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("closeout-#{inspect(ref)}") end)
      user = email_user!(address("telemetry"))
      Gyms.preview_gym_join(ctx.code, client_ip())
      {:ok, view, :created} = join(user, ctx.code)
      join(user, "ZZZZ-ZZZZ")

      for _ <- 1..3 do
        assert_receive {^ref, _event, metadata}
        assert Map.keys(metadata) == [:outcome]
        refute inspect(metadata) =~ String.replace(ctx.code, "-", "")
        refute inspect(metadata) =~ view.gym_member_id
      end
    end
  end

  describe "CSV boundary" do
    test "only the dry run is routed; no commit operation exists anywhere" do
      routes =
        SimpleFitWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.map(& &1.path)
        |> Enum.filter(&String.contains?(&1, "import"))

      assert routes == ["/api/v1/gyms/:gym_id/member-imports/preview"]

      spec_paths =
        SimpleFitWeb.ApiSpec.spec().paths
        |> Map.keys()
        |> Enum.filter(&String.contains?(&1, "import"))

      assert spec_paths == ["/api/v1/gyms/{gym_id}/member-imports/preview"]

      for module <- [Gyms, SimpleFit.Gyms.MemberImport],
          {name, _arity} <- module.__info__(:functions) do
        refute name |> Atom.to_string() |> String.contains?("commit"),
               "#{inspect(module)}.#{name}"
      end
    end
  end

  describe "invite_members milestone" do
    test "a queued invitation, a pending request and a list preview do not complete it; an acceptance does",
         ctx do
      status = fn ->
        {:ok, state} = Gyms.get_first_run(ctx.owner, ctx.gym.id)
        Enum.find(state.checklist, &(&1.key == :invite_members)).status
      end

      email = address("milestone")
      invitation = invite_member!(ctx.owner, ctx.gym.id, email)
      requester!(ctx.code)

      {:ok, _} =
        Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{
          "csv" => "email\nsomeone@example.com\n#{email}\n"
        })

      assert status.() == :available

      user = email_user!(email)

      {:ok, _} =
        Gyms.accept_member_invitation(
          user,
          live_session!(user),
          {:id, invitation.invitation_id},
          client_ip()
        )

      assert status.() == :completed
    end
  end
end
