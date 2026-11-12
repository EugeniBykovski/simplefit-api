defmodule SimpleFitWeb.OperatorGovernanceTest do
  @moduledoc """
  SF-129 over HTTP, checked against OpenAPI: the operator governance projections on top
  of SF-110/SF-111. The inventory and detail carry each permission's provenance, the
  account's short name and the last key check, never an address or anything about keys
  beyond their count; the permission catalog; provisioning by exact email (one account
  reference, never part of one, an unknown address refused like an ineligible account);
  no self-grant, self-suspension or self-provisioning; the last manager kept by
  construction; and nothing for product roles.
  """

  use SimpleFitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import OpenApiSpex.TestAssertions
  import SimpleFit.GymHelpers
  import SimpleFit.OperatorHelpers

  alias SimpleFit.{Accounts, Operators, Repo}
  alias SimpleFit.Operators.{Grant, Operator, Policy}
  alias SimpleFitWeb.ApiSpec

  @admin "/api/v1/admin"

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    :ok
  end

  defp founder! do
    user = registered_as!(registered!("founder"), "Ewa Nowak")
    {:ok, credentials} = Accounts.create_session(user)
    operator = bootstrap!(user)
    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)

    %{
      user: user,
      token: credentials.access_token,
      session: credentials.session,
      operator: operator
    }
  end

  defp provisioned!(founder, permissions, name \\ "Piotr Rybak") do
    user = registered_as!(registered!("operator"), name)
    {:ok, credentials} = Accounts.create_session(user)

    {:ok, %{operator: op}} =
      Operators.provision(
        founder.user,
        founder.session,
        Map.merge(op("access_request_approved"), %{
          "user_id" => user.id,
          "permissions" => permissions
        })
      )

    [key | _] = enroll!(user, credentials.session)
    _ = step_up!(user, credentials.session, key)
    %{user: user, token: credentials.access_token, session: credentials.session, operator: op}
  end

  # An account with an email sign-in identity and completed registration.
  defp email_account!(email) do
    {:ok, user} = Accounts.register_user(:email, email)

    {:ok, _} =
      Accounts.update_account_registration(user, %{
        "full_name" => "Jan Wiśniewski",
        "date_of_birth" => "1990-04-12",
        "accept_terms" => true,
        "accept_privacy" => true
      })

    {:ok, %{status: :complete}} = Accounts.complete_account_registration(user)
    user
  end

  defp get_json(path, token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(path)

  defp post_json(path, token, body),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  describe "inventory and detail" do
    test "short names, provenance and the last key check; never an address or key detail" do
      founder = founder!()
      reader = provisioned!(founder, ["operators.read", "audit.read"])
      pending_user = registered_as!(registered!("pending"), "Marta Dąbrowska")

      {:ok, _} =
        Operators.provision(
          founder.user,
          founder.session,
          Map.merge(op(), %{"user_id" => pending_user.id, "permissions" => ["gyms.read"]})
        )

      body = get_json("#{@admin}/operators", reader.token) |> json_response(200)
      assert_schema(body, "OperatorListResponse", ApiSpec.spec())
      [first, second, third] = body["operators"]

      assert first["id"] == founder.operator.id
      assert first["short_name"] == "Ewa N."
      assert first["bootstrap"]
      assert is_binary(first["last_key_check_at"])
      assert Enum.all?(first["grants"], & &1["bootstrap"])

      assert Enum.sort(Enum.map(first["grants"], & &1["permission"])) ==
               Enum.sort(first["permissions"])

      assert second["short_name"] == "Piotr R."

      assert [
               %{
                 "permission" => "audit.read",
                 "granted_by_operator_id" => by,
                 "reason_code" => "access_request_approved",
                 "bootstrap" => false
               },
               %{"permission" => "operators.read"}
             ] = second["grants"]

      assert by == founder.operator.id

      # Pending: no key, no key check yet; the status says what's missing.
      assert %{"status" => "pending_enrollment", "last_key_check_at" => nil} = third
      assert third["security_keys"] == %{"registered" => 0, "required" => 2}

      json = Jason.encode!(body)
      refute json =~ "@"
      refute json =~ "Nowak"
      refute json =~ "credential_id"
      refute json =~ "public_key"

      detail = get_json("#{@admin}/operators/#{second["id"]}", reader.token) |> json_response(200)
      assert_schema(detail, "OperatorSummaryResponse", ApiSpec.spec())
      assert detail["operator"]["grants"] == second["grants"]
    end

    test "the catalog: every permission with its assurance, no role or bundle" do
      founder = founder!()
      body = get_json("#{@admin}/operator-permissions", founder.token) |> json_response(200)
      assert_schema(body, "OperatorPermissionCatalogResponse", ApiSpec.spec())
      keys = Enum.map(body["permissions"], & &1["permission"])
      assert keys == Policy.permissions()

      assert %{"permission" => "operators.manage", "assurance" => "fresh_key"} in body[
               "permissions"
             ]

      refute Enum.any?(keys, &(&1 =~ ~r/admin|super|all|\*/))
    end

    test "product roles and operators without operators.read learn nothing" do
      founder = founder!()
      owner = registered!("owner")
      _gym = completed_gym!(owner)
      {:ok, session} = Accounts.create_session(owner)
      other = provisioned!(founder, ["gyms.read"])

      for path <- [
            "#{@admin}/operators",
            "#{@admin}/operators/#{founder.operator.id}",
            "#{@admin}/operator-permissions"
          ] do
        assert build_conn() |> get(path) |> json_response(401)

        assert %{"error" => %{"code" => "not_found"}} =
                 get_json(path, session.access_token) |> json_response(404)

        assert %{"error" => %{"code" => "forbidden"}} =
                 get_json(path, other.token) |> json_response(403)
      end
    end
  end

  describe "provisioning" do
    test "by exact email: one account reference; unknown refused like ineligible; never oneself" do
      founder = founder!()
      email = "governance-#{System.unique_integer([:positive])}@example.com"
      target = email_account!(email)

      body = fn ref ->
        Map.merge(
          op("access_request_approved"),
          Map.merge(%{"permissions" => ["audit.read"]}, ref)
        )
      end

      conn =
        post_json("#{@admin}/operators", founder.token, body.(%{"email" => String.upcase(email)}))

      created = json_response(conn, 200)
      assert_schema(created, "OperatorSummaryResponse", ApiSpec.spec())

      assert %{
               "status" => "pending_enrollment",
               "user_id" => user_id,
               "permissions" => ["audit.read"]
             } = created["operator"]

      assert user_id == target.id

      assert %{"error" => %{"code" => "conflict", "details" => %{"user" => "not_eligible"}}} =
               post_json(
                 "#{@admin}/operators",
                 founder.token,
                 body.(%{"email" => "nobody-#{System.unique_integer([:positive])}@example.com"})
               )
               |> json_response(409)

      for ref <- [%{}, %{"email" => email, "user_id" => target.id}] do
        assert %{"error" => %{"code" => "validation_error"}} =
                 post_json("#{@admin}/operators", founder.token, body.(ref)) |> json_response(422)
      end

      assert %{"error" => %{"code" => "conflict", "details" => %{"target" => "self"}}} =
               post_json(
                 "#{@admin}/operators",
                 founder.token,
                 body.(%{"user_id" => founder.user.id})
               )
               |> json_response(409)

      # A partial address is no address.
      assert %{"error" => %{"code" => "conflict", "details" => %{"user" => "not_eligible"}}} =
               post_json(
                 "#{@admin}/operators",
                 founder.token,
                 body.(%{"email" => String.slice(email, 0, 5)})
               )
               |> json_response(409)

      # Provisioning grants authority to nobody until keys are registered.
      operator = Repo.get!(Operator, created["operator"]["id"])
      {:ok, session} = Accounts.create_session(target)

      assert {:error, :enrollment_required} =
               Operators.authorize(target, session.session, "audit.read")

      assert operator.status == :pending_enrollment
    end
  end

  describe "self and the last manager" do
    test "no self-grant, self-suspension or self-revocation: the account, not the session, decides" do
      founder = founder!()

      for {action, params} <- [
            {"operator.permission.grant", %{"permission" => "billing.read"}},
            {"operator.suspend", %{}},
            {"operator.revoke", %{}},
            {"operator.permission.revoke", %{"permission" => "operators.manage"}}
          ] do
        assert {:error, {:conflict, %{target: "self"}}} =
                 Operators.preview(
                   action,
                   founder.user,
                   founder.session,
                   founder.operator.id,
                   Map.merge(%{"reason_code" => reason(action)}, params)
                 )
      end

      assert Repo.aggregate(from(g in Grant, where: g.permission == "billing.read"), :count) == 0
    end

    test "two managers: after one removes the other's manage permission, the other can't remove anyone's" do
      founder = founder!()
      b = provisioned!(founder, ["operators.read", "operators.manage"])

      {:ok, _} =
        act(founder.user, founder.session, "operator.permission.revoke", b.operator.id, %{
          "permission" => "operators.manage"
        })

      # B no longer manages: the founder, now the last manager, can't be touched by B.
      assert {:error, :forbidden} =
               Operators.preview("operator.suspend", b.user, b.session, founder.operator.id, %{
                 "reason_code" => "security_concern"
               })

      managers =
        Repo.aggregate(
          from(o in Operator,
            join: g in Grant,
            on:
              g.operator_id == o.id and g.permission == "operators.manage" and
                is_nil(g.revoked_at),
            where: o.status == :active
          ),
          :count
        )

      assert managers == 1
    end
  end
end
