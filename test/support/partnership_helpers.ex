defmodule SimpleFit.PartnershipHelpers do
  @moduledoc """
  SF-130 test helpers: partnership proposals through the real
  `SimpleFit.Sponsors.Partnerships` functions, and operators who review them.
  """

  import SimpleFit.OperatorHelpers
  import SimpleFit.GymHelpers, only: [registered!: 1, live_session!: 1]

  alias SimpleFit.Accounts.User
  alias SimpleFit.{Operators, Repo}
  alias SimpleFit.Sponsors.{Partnerships, Proposal}

  @review ~w(sponsors.proposals.read sponsors.proposals.claim sponsors.proposals.request_changes
             sponsors.proposals.accept sponsors.proposals.decline)

  @doc "Every proposal review permission."
  def review_permissions, do: @review

  @doc "A complete set of proposal answers, with `overrides` on top."
  def proposal_answers(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Regional boxing event partnership",
        "interests" => ["sponsored_events", "community_campaigns"],
        "market_scope" => "countries",
        "market_countries" => ["PL", "DE"],
        "market_cities" => [],
        "summary" =>
          "We would like to explore supporting amateur boxing events in Poland and Germany."
      },
      overrides
    )
  end

  @doc "Creates a draft proposal as `user` in `org` (asserting success)."
  def draft_proposal!(%User{} = user, org, answers \\ proposal_answers()) do
    {:ok, view} =
      Partnerships.create_proposal(
        user,
        org.id,
        Map.put(answers, "client_request_id", Ecto.UUID.generate())
      )

    view.proposal
  end

  @doc "A submit or withdraw request for `proposal` at its current revision."
  def command(%Proposal{} = proposal),
    do: %{
      "expected_revision" => Repo.reload!(proposal).revision,
      "client_request_id" => Ecto.UUID.generate()
    }

  @doc "Submits `proposal` as `user` (asserting success)."
  def submitted_proposal!(%User{} = user, org, %Proposal{} = proposal) do
    {:ok, view} = Partnerships.submit_proposal(user, org.id, proposal.id, command(proposal))
    view.proposal
  end

  @doc "A bootstrapped founder operator with `permissions` and a fresh key check."
  def founder!(permissions) do
    user = registered!("reviewer")
    session = live_session!(user)
    op = bootstrap!(user, permissions)
    [k | _] = enroll!(user, session)
    %{user: user, session: session, operator: op, key: step_up!(user, session, k)}
  end

  @doc "An operator provisioned by `founder` for `user` with `permissions`."
  def operator_for!(founder, %User{} = user, permissions) do
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

  @doc "Executes an action that needs no confirmation (claim, request changes)."
  def exec(r, action, %Proposal{} = proposal, params) do
    Operators.execute(
      action,
      r.user,
      r.session,
      proposal.id,
      Map.merge(
        %{
          "expected_revision" => Repo.reload!(proposal).revision,
          "operation_id" => Ecto.UUID.generate()
        },
        params
      )
    )
  end

  @doc "Claims `proposal` as `r`."
  def claim(r, proposal),
    do: exec(r, "sponsor_proposal.claim", proposal, %{"reason_code" => "review_started"})

  @doc "Previews, then executes a confirmed decision (accept, decline) with `reason`."
  def decide(r, action, %Proposal{} = proposal, reason) do
    with {:ok, preview} <-
           Operators.preview(action, r.user, r.session, proposal.id, %{"reason_code" => reason}) do
      Operators.execute(action, r.user, r.session, proposal.id, %{
        "reason_code" => reason,
        "expected_revision" => preview.expected_revision,
        "operation_id" => Ecto.UUID.generate(),
        "confirmation_token" => preview.confirmation.token
      })
    end
  end
end
