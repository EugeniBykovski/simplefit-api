defmodule SimpleFitWeb.SponsorFirstRunJSON do
  @moduledoc "JSON rendering of the partner portal first run (`SponsorFirstRun`); fields picked explicitly."

  def show(%{first_run: first_run}) do
    %{
      first_run: %{
        sponsor_id: first_run.sponsor_id,
        status: Atom.to_string(first_run.status),
        started_at: first_run.started_at,
        completed_at: first_run.completed_at,
        dismissed_at: first_run.dismissed_at
      }
    }
  end
end
