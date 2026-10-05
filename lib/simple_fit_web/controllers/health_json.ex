defmodule SimpleFitWeb.HealthJSON do
  @moduledoc "JSON rendering for `SimpleFitWeb.HealthController`."

  @spec show(map()) :: %{status: String.t(), service: String.t()}
  def show(_assigns) do
    %{status: "ok", service: "simplefit-api"}
  end
end
