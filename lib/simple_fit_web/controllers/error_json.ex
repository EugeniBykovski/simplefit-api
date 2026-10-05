defmodule SimpleFitWeb.ErrorJSON do
  @moduledoc """
  Renders the API error envelope for exceptions raised while handling a
  request (unknown routes, malformed JSON, unsupported content types,
  crashes, ...).

  Invoked by the endpoint through `render_errors` (see config/config.exs).
  The status comes from the exception's `Plug.Exception` implementation; the
  exception itself is never rendered. See `SimpleFitWeb.APIError`.
  """

  alias SimpleFitWeb.APIError

  @spec render(String.t(), map()) :: APIError.envelope()
  def render(template, assigns) do
    status = Map.get_lazy(assigns, :status, fn -> status_from_template(template) end)
    APIError.envelope(status, request_id: request_id(assigns))
  end

  defp status_from_template(template) do
    template |> String.split(".", parts: 2) |> hd() |> String.to_integer()
  end

  # Prefer the id on the response; fall back to the Logger metadata set by
  # Plug.RequestId for errors raised before the conn carried the header.
  defp request_id(%{conn: %Plug.Conn{} = conn}) do
    case Plug.Conn.get_resp_header(conn, "x-request-id") do
      [request_id | _] -> request_id
      [] -> logger_request_id()
    end
  end

  defp request_id(_assigns), do: logger_request_id()

  defp logger_request_id, do: Logger.metadata()[:request_id]
end
