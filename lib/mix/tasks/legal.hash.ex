defmodule Mix.Tasks.Legal.Hash do
  @shortdoc "Prints the content hash of a legal document language variant"
  @moduledoc """
  Prints the SHA-256 that `registry.json` must record for one language
  variant of a legal document version (ADR 0022):

      mix legal.hash priv/legal/documents/coach-data-rules/<version>/en

  The directory holds `title.md`, `summary.md`, `checkbox.md` and `full.md`.
  Prints only the hash, never the text.
  """

  use Mix.Task

  alias SimpleFit.Legal.Registry

  @impl Mix.Task
  def run([dir]) do
    case Registry.read_parts(dir) do
      {:ok, parts} -> Mix.shell().info(Registry.content_sha256(parts))
      {:error, reason} -> Mix.raise("cannot hash #{dir}: #{reason}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix legal.hash <variant directory>")
end
