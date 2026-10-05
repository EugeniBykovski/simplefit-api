defmodule Mix.Tasks.Openapi.Gen do
  @shortdoc "Generates the canonical OpenAPI artifact"

  @moduledoc """
  Generates `openapi/simplefit.api.json` from `SimpleFitWeb.ApiSpec`.

      $ mix openapi.gen

  Run it after any change to routes, operations or schemas and commit the
  result together with the code change. Output is deterministic.
  """

  use Mix.Task

  alias SimpleFitWeb.ApiSpec

  @requirements ["compile"]

  @impl Mix.Task
  def run(_args) do
    path = ApiSpec.artifact_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ApiSpec.to_json())
    Mix.shell().info("Wrote #{path}")
  end
end
