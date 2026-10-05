defmodule SimpleFitWeb.Schemas.Examples do
  @moduledoc """
  Fixed example values shared by OpenAPI schemas. Examples must be constant
  so the generated OpenAPI artifact is deterministic.
  """

  @doc "Example `x-request-id` value."
  @spec request_id() :: String.t()
  def request_id, do: "GHx3kP0vZ8sAAAAB"
end
