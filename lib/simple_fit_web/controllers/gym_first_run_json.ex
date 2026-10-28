defmodule SimpleFitWeb.GymFirstRunJSON do
  @moduledoc """
  JSON rendering of a gym first run (`GymFirstRun`). Views are the
  projections built by `SimpleFit.Gyms`; fields are picked explicitly.
  """

  def show(%{first_run: first_run}) do
    %{
      first_run: %{
        gym_id: first_run.gym_id,
        status: Atom.to_string(first_run.status),
        started_at: first_run.started_at,
        completed_at: first_run.completed_at,
        dismissed_at: first_run.dismissed_at,
        checklist:
          Enum.map(first_run.checklist, fn item ->
            %{key: Atom.to_string(item.key), status: Atom.to_string(item.status)}
          end)
      }
    }
  end
end
