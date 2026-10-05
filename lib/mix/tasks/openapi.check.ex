defmodule Mix.Tasks.Openapi.Check do
  @shortdoc "Validates the OpenAPI spec and detects contract drift"

  @moduledoc """
  Fails when the API contract is invalid or out of date.

      $ mix openapi.check

  Checks, in order:

    1. the spec passes `SimpleFitWeb.ApiSpec.Validation` (operation ids,
       summaries, tags, examples valid against their schemas)
    2. `openapi/simplefit.api.json` is byte-for-byte identical to the spec
       generated from code, i.e. every contract change was regenerated with
       `mix openapi.gen` and committed

  Part of `mix quality` and CI.
  """

  use Mix.Task

  alias SimpleFitWeb.ApiSpec
  alias SimpleFitWeb.ApiSpec.Validation

  @requirements ["compile"]

  @impl Mix.Task
  def run(_args) do
    spec = ApiSpec.spec()

    case Validation.validate(spec) do
      :ok ->
        :ok

      {:error, problems} ->
        Mix.raise("OpenAPI spec is invalid:\n\n" <> Enum.map_join(problems, "\n", &"  * #{&1}"))
    end

    path = ApiSpec.artifact_path()
    generated = ApiSpec.to_json(spec)

    case File.read(path) do
      {:ok, ^generated} ->
        Mix.shell().info("OpenAPI contract OK (#{path})")

      {:ok, _stale} ->
        Mix.raise("""
        #{path} does not match the spec generated from code (contract drift).

        Run `mix openapi.gen`, review the diff and commit it with your change.
        """)

      {:error, reason} ->
        Mix.raise("Could not read #{path}: #{:file.format_error(reason)}. Run `mix openapi.gen`.")
    end
  end
end
