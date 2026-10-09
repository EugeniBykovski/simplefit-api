defmodule SimpleFitWeb.FirstRunJSON do
  @moduledoc "JSON rendering for `SimpleFitWeb.FirstRunController`."

  alias SimpleFit.FirstRun

  @spec index(%{experiences: [FirstRun.state()]}) :: %{experiences: [map()]}
  def index(%{experiences: experiences}), do: %{experiences: Enum.map(experiences, &experience/1)}

  @spec show(%{experience: FirstRun.state()}) :: %{experience: map()}
  def show(%{experience: experience}), do: %{experience: experience(experience)}

  defp experience(state) do
    %{experience: state.experience, status: state.status, recorded_at: state.recorded_at}
  end
end
