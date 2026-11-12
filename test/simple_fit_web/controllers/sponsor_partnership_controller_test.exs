defmodule SimpleFitWeb.SponsorPartnershipControllerTest do
  @moduledoc """
  SF-130 over HTTP, checked against OpenAPI: the sponsor's partnership policy,
  opportunities, preferences and proposal lifecycle, its concealment and isolation,
  and the operator review endpoints (queue, detail, claim, request changes, accept,
  decline). Responses never carry an operator's identity, a review reason, a budget
  or anything commercial.
  """

  use SimpleFitWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import SimpleFit.OperatorHelpers
  import SimpleFit.PartnershipHelpers, only: [proposal_answers: 0, review_permissions: 0]
  import SimpleFit.SponsorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1]

  alias SimpleFit.Accounts
  alias SimpleFitWeb.ApiSpec

  @admin "/api/v1/admin/sponsor-proposals"

  defp session!(user) do
    {:ok, credentials} = Accounts.create_session(user)
    {credentials.access_token, credentials.session}
  end

  defp token!(user), do: user |> session!() |> elem(0)

  defp call(method, path, token, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, Jason.encode!(body || %{}))
      :patch -> patch(conn, path, Jason.encode!(body))
    end
  end

  setup do
    on_exit(&untrust_ceremony_keys!/0)
    owner = registered!("owner")
    member = registered!("member")
    outsider = registered!("outsider")
    %{organization: org} = provision!(owner)
    member!(org, member, :member)

    %{
      org: org,
      base: "/api/v1/sponsor-organizations/#{org.id}",
      owner: token!(owner),
      member: token!(member),
      outsider: token!(outsider)
    }
  end

  test "policy and opportunities: truthful, with no inventory", c do
    policy = call(:get, "/api/v1/sponsor-partnership-policy", c.member) |> json_response(200)
    assert_schema(policy, "SponsorPartnershipPolicyResponse", ApiSpec.spec())
    assert policy["policy"]["open_limit"] == 25
    refute Jason.encode!(policy) =~ "budget"

    opportunities =
      call(:get, c.base <> "/partnership-opportunities", c.member) |> json_response(200)

    assert_schema(opportunities, "SponsorPartnershipOpportunitiesResponse", ApiSpec.spec())
    assert %{"availability" => "unavailable", "reason" => "no_inventory"} = opportunities

    assert %{"error" => %{"code" => "not_found"}} =
             call(:get, c.base <> "/partnership-opportunities", c.outsider) |> json_response(404)
  end

  test "preferences: read by members, written by the owner with revisions", c do
    empty = call(:get, c.base <> "/partnership-preferences", c.member) |> json_response(200)
    assert_schema(empty, "SponsorPartnershipPreferencesResponse", ApiSpec.spec())
    assert %{"preferences" => nil, "application_answers" => nil, "can_edit" => false} = empty

    body = %{"expected_revision" => 0, "interests" => ["content"], "market_scope" => "global"}

    assert %{"error" => %{"code" => "forbidden"}} =
             call(:patch, c.base <> "/partnership-preferences", c.member, body)
             |> json_response(403)

    saved =
      call(:patch, c.base <> "/partnership-preferences", c.owner, body) |> json_response(200)

    assert_schema(saved, "SponsorPartnershipPreferencesResponse", ApiSpec.spec())
    assert %{"revision" => 1, "interests" => ["content"]} = saved["preferences"]

    assert %{"error" => %{"code" => "revision_conflict", "details" => %{"current_revision" => 1}}} =
             call(:patch, c.base <> "/partnership-preferences", c.owner, body)
             |> json_response(409)

    assert %{"error" => %{"code" => "validation_error"}} =
             call(:patch, c.base <> "/partnership-preferences", c.owner, %{
               "expected_revision" => 1,
               "budget_band" => "eur_under_5000"
             })
             |> json_response(422)
  end

  test "the proposal lifecycle over HTTP, then the operator's review", c do
    key = Ecto.UUID.generate()
    body = Map.put(proposal_answers(), "client_request_id", key)

    created =
      call(:post, c.base <> "/partnership-proposals", c.owner, body) |> json_response(201)

    assert_schema(created, "SponsorPartnershipProposalResponse", ApiSpec.spec())
    p = created["proposal"]
    assert %{"status" => "draft", "binding" => false, "kind" => "general_inquiry"} = p
    assert p["allowed_actions"] == %{"edit" => true, "submit" => true, "withdraw" => true}
    id = p["proposal_id"]

    # The same create again answers the same draft.
    assert %{"proposal" => %{"proposal_id" => ^id}} =
             call(:post, c.base <> "/partnership-proposals", c.owner, body) |> json_response(201)

    assert %{"error" => %{"code" => "forbidden"}} =
             call(:post, c.base <> "/partnership-proposals", c.member, %{
               body
               | "client_request_id" => Ecto.UUID.generate()
             })
             |> json_response(403)

    list = call(:get, c.base <> "/partnership-proposals", c.member) |> json_response(200)
    assert_schema(list, "SponsorPartnershipProposalListResponse", ApiSpec.spec())
    assert [%{"proposal_id" => ^id, "status" => "draft"}] = list["proposals"]
    assert list["can_create"] == false

    assert %{"error" => %{"code" => "not_found"}} =
             call(:get, "#{c.base}/partnership-proposals/#{id}", c.outsider) |> json_response(404)

    updated =
      call(:patch, "#{c.base}/partnership-proposals/#{id}", c.owner, %{
        "expected_revision" => 1,
        "title" => "Spring events"
      })
      |> json_response(200)

    assert_schema(updated, "SponsorPartnershipProposalResponse", ApiSpec.spec())

    submit = %{"expected_revision" => 2, "client_request_id" => Ecto.UUID.generate()}

    submitted =
      call(:post, "#{c.base}/partnership-proposals/#{id}/submit", c.owner, submit)
      |> json_response(200)

    assert_schema(submitted, "SponsorPartnershipProposalResponse", ApiSpec.spec())
    assert %{"status" => "submitted", "submissions" => [_]} = submitted["proposal"]

    assert %{"proposal" => %{"status" => "submitted", "submissions" => [_]}} =
             call(:post, "#{c.base}/partnership-proposals/#{id}/submit", c.owner, submit)
             |> json_response(200)

    # The operator.
    operator = registered!("reviewer")
    {op_token, session} = session!(operator)
    _ = bootstrap!(operator, review_permissions())
    [k | _] = enroll!(operator, session)
    _ = step_up!(operator, session, k)

    queue = call(:get, @admin, op_token) |> json_response(200)
    assert_schema(queue, "SponsorProposalQueueResponse", ApiSpec.spec())
    assert [%{"proposal_id" => ^id, "organization" => %{"sponsor_id" => _}}] = queue["proposals"]

    detail = call(:get, "#{@admin}/#{id}", op_token) |> json_response(200)
    assert_schema(detail, "SponsorProposalReviewResponse", ApiSpec.spec())
    assert detail["proposal"]["latest_submission"]["answers"]["title"] == "Spring events"
    refute Jason.encode!(detail) =~ "@"

    claimed =
      call(:post, "#{@admin}/#{id}/claim", op_token, %{
        "reason_code" => "review_started",
        "expected_revision" => detail["proposal"]["revision"],
        "operation_id" => Ecto.UUID.generate()
      })
      |> json_response(200)

    assert_schema(claimed, "SponsorProposalReviewResponse", ApiSpec.spec())

    changes =
      call(:post, "#{@admin}/#{id}/request-changes", op_token, %{
        "reason_code" => "unclear_request",
        "fields" => ["summary"],
        "message" => "Which cities?",
        "expected_revision" => claimed["proposal"]["revision"],
        "operation_id" => Ecto.UUID.generate()
      })
      |> json_response(200)

    assert changes["proposal"]["status"] == "changes_requested"

    seen = call(:get, "#{c.base}/partnership-proposals/#{id}", c.member) |> json_response(200)
    assert_schema(seen, "SponsorPartnershipProposalResponse", ApiSpec.spec())

    assert %{"fields" => ["summary"], "message" => "Which cities?"} =
             seen["proposal"]["change_request"]

    assert List.last(seen["proposal"]["history"])["actor"] == "simplefit"
    refute Jason.encode!(seen) =~ "unclear_request"

    revision = seen["proposal"]["revision"]

    call(:patch, "#{c.base}/partnership-proposals/#{id}", c.owner, %{
      "expected_revision" => revision,
      "summary" => "Warsaw and Berlin."
    })
    |> json_response(200)

    resubmitted =
      call(:post, "#{c.base}/partnership-proposals/#{id}/submit", c.owner, %{
        "expected_revision" => revision + 1,
        "client_request_id" => Ecto.UUID.generate()
      })
      |> json_response(200)

    assert resubmitted["proposal"]["status"] == "submitted"

    reclaimed =
      call(:post, "#{@admin}/#{id}/claim", op_token, %{
        "reason_code" => "review_started",
        "expected_revision" => resubmitted["proposal"]["revision"],
        "operation_id" => Ecto.UUID.generate()
      })
      |> json_response(200)

    decision = %{"reason_code" => "follow_up_planned"}

    preview =
      call(:post, "#{@admin}/#{id}/accept/preview", op_token, decision) |> json_response(200)

    assert_schema(preview, "OperatorActionPreviewResponse", ApiSpec.spec())

    assert %{"error" => %{"code" => "confirmation_required"}} =
             call(:post, "#{@admin}/#{id}/accept", op_token, %{
               "reason_code" => "follow_up_planned",
               "expected_revision" => reclaimed["proposal"]["revision"],
               "operation_id" => Ecto.UUID.generate()
             })
             |> json_response(428)

    accepted =
      call(:post, "#{@admin}/#{id}/accept", op_token, %{
        "reason_code" => "follow_up_planned",
        "expected_revision" => reclaimed["proposal"]["revision"],
        "operation_id" => Ecto.UUID.generate(),
        "confirmation_token" => preview["preview"]["confirmation"]["token"]
      })
      |> json_response(200)

    assert_schema(accepted, "SponsorProposalReviewResponse", ApiSpec.spec())
    assert accepted["proposal"]["status"] == "accepted"

    final = call(:get, "#{c.base}/partnership-proposals/#{id}", c.owner) |> json_response(200)
    assert %{"status" => "accepted", "binding" => false} = final["proposal"]
    assert final["proposal"]["allowed_actions"]["withdraw"] == false

    # Without an operator, the admin routes don't exist.
    assert call(:get, @admin, c.owner) |> json_response(404)
    assert call(:get, "#{@admin}/#{id}", c.owner) |> json_response(404)
  end
end
