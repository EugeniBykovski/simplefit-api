defmodule SimpleFitWeb.SponsorPartnershipJSON do
  @moduledoc """
  Partnership DTOs for sponsor members (SF-130). Fields are picked explicitly: never
  an operator's identity or a review reason code, never the creating request's
  digest.
  """

  alias SimpleFit.Sponsors.{PartnershipPreferences, Proposal}

  def policy(%{policy: policy}), do: %{policy: policy}

  def opportunities(%{result: result}),
    do: %{
      sponsor_id: result.sponsor_id,
      availability: result.availability,
      reason: result.reason
    }

  def preferences(%{view: view}) do
    %{
      sponsor_id: view.sponsor_id,
      preferences: preferences_dto(view.preferences),
      application_answers: view.application_answers,
      can_edit: view.can_edit
    }
  end

  def index(%{page: page}) do
    %{
      sponsor_id: page.sponsor_id,
      proposals: Enum.map(page.entries, &summary/1),
      next_cursor: page.next_cursor,
      can_create: page.can_create
    }
  end

  def show(%{view: view}), do: %{proposal: proposal(view)}

  defp preferences_dto(nil), do: nil

  defp preferences_dto(%PartnershipPreferences{} = p) do
    %{
      revision: p.revision,
      interests: p.interests,
      market_scope: p.market_scope,
      market_countries: p.market_countries,
      market_cities: p.market_cities,
      goals: p.goals,
      updated_at: p.updated_at
    }
  end

  defp summary(%{proposal: %Proposal{} = p, change_request_open: open}) do
    %{
      proposal_id: p.id,
      kind: p.kind,
      status: p.status,
      revision: p.revision,
      title: p.title,
      interests: p.interests,
      change_request_open: open,
      created_at: p.inserted_at,
      updated_at: p.updated_at,
      submitted_at: p.submitted_at,
      decided_at: p.decided_at,
      withdrawn_at: p.withdrawn_at
    }
  end

  defp proposal(%{proposal: %Proposal{} = p} = view) do
    %{
      proposal_id: p.id,
      sponsor_id: view.sponsor_id,
      kind: p.kind,
      status: p.status,
      revision: p.revision,
      binding: false,
      answers: answers(p),
      missing_fields: view.missing,
      allowed_actions: view.actions,
      change_request: change_request(view.change_request),
      submissions:
        Enum.map(view.submissions, fn s ->
          %{submission_id: s.id, sequence: s.sequence, submitted_at: s.submitted_at}
        end),
      history: Enum.map(view.history, &history/1),
      created_by: %{short_name: view.created_by, is_viewer: view.created_by_viewer},
      created_at: p.inserted_at,
      updated_at: p.updated_at,
      submitted_at: p.submitted_at,
      decided_at: p.decided_at,
      withdrawn_at: p.withdrawn_at
    }
  end

  @doc false
  def answers(%Proposal{} = p) do
    %{
      title: p.title,
      interests: p.interests,
      market_scope: p.market_scope,
      market_countries: p.market_countries,
      market_cities: p.market_cities,
      summary: p.summary
    }
  end

  defp change_request(nil), do: nil

  defp change_request(request),
    do: %{fields: request.fields, message: request.message, requested_at: request.requested_at}

  defp history(event) do
    %{
      from_status: event.from_status,
      to_status: event.to_status,
      occurred_at: event.occurred_at,
      actor: if(event.actor_kind == :operator, do: "simplefit", else: "sponsor_member")
    }
  end
end
