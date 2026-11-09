defmodule Mix.Tasks.Operators.Ceremony do
  @shortdoc "Runs a signed operator ceremony statement (bootstrap or recovery)"
  @moduledoc """
  Verifies and consumes one signed ceremony statement (SF-110, ADR 0028):

      mix operators.ceremony PATH

  The statement carries everything: purpose, environment, user id, permissions,
  ceremony id and validity. No argument names a person or grants anything; a
  statement not signed by a trusted key is refused and audited. A production build
  trusts only keys compiled in from reviewed configuration, and has none today.
  In a release, call `SimpleFit.Operators.Bootstrap.run_file/1` instead.
  """

  use Mix.Task

  alias SimpleFit.Operators.Bootstrap

  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]) do
    case Bootstrap.run_file(path) do
      {:ok, operator} ->
        Mix.shell().info("ceremony consumed: operator #{operator.id} is #{operator.status}")

      {:error, reason} ->
        Mix.raise("ceremony refused: #{reason}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix operators.ceremony PATH")
end
