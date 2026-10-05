defmodule SimpleFitWeb.APIError do
  @moduledoc """
  The SimpleFit API error contract.

  Every non-2xx response carries the same JSON envelope:

      {
        "error": {
          "code": "not_found",
          "message": "The requested resource was not found",
          "details": {},
          "request_id": "GHx3kP0v..."
        }
      }

    * `code` - stable, machine-readable, snake_case. Clients branch on this,
      never on `message`. New codes may be added; clients must fall back to
      the HTTP status for codes they do not recognise.
    * `message` - human-readable English summary. Safe to log, not meant
      for end users, may change without notice.
    * `details` - object with code-specific structured data. Always present,
      empty when there is nothing to add. For `validation_error` it holds
      `fields` (field name to a list of human-readable messages, SF-2) and
      `field_codes` (the same entries, in the same order, as stable reason
      codes such as `required` or `already_exists`, SF-6). See
      `SimpleFitWeb.ChangesetErrors`.
    * `request_id` - the `x-request-id` of the request, for support and log
      correlation. `null` only if no request id was assigned.

  Messages are fixed per code. Exception messages, stack traces and other
  internals never reach the response body: the public error is built only
  from the catalog below, while the internal diagnosis (exception, reason,
  stack) goes to the server log with the same `request_id`.

  This module is the single source of truth for codes. The OpenAPI error
  schemas (`SimpleFitWeb.Schemas.Error*`) and `SimpleFitWeb.ErrorJSON` are
  built from it. See docs/architecture/adr/0003-api-versioning-and-errors.md.
  """

  alias Plug.Conn
  alias Plug.Conn.Status

  @typedoc "A machine-readable error code."
  @type code :: String.t()

  @typedoc "The JSON error envelope, ready to be encoded."
  @type envelope :: %{
          error: %{
            code: code(),
            message: String.t(),
            details: map(),
            request_id: String.t() | nil
          }
        }

  # {code, HTTP status, message}
  @catalog [
    {"bad_request", 400, "The request could not be processed"},
    {"unauthorized", 401, "Authentication is required"},
    {"forbidden", 403, "You do not have permission to perform this action"},
    {"not_found", 404, "The requested resource was not found"},
    {"not_acceptable", 406, "The requested response format is not supported"},
    {"conflict", 409, "The request conflicts with the current state of the resource"},
    {"payload_too_large", 413, "The request body is too large"},
    {"unsupported_media_type", 415, "The request content type is not supported"},
    {"validation_error", 422, "Request validation failed"},
    {"rate_limited", 429, "Too many requests, retry later"},
    {"internal_error", 500, "An unexpected error occurred"},
    {"service_unavailable", 503, "The service is temporarily unavailable"}
  ]

  @codes Enum.map(@catalog, &elem(&1, 0))

  @doc "All catalogued error codes, in catalog order."
  @spec codes() :: [code()]
  def codes, do: @codes

  @doc "The HTTP status for a catalogued code."
  @spec status(code()) :: 100..599
  for {code, status, _message} <- @catalog do
    def status(unquote(code)), do: unquote(status)
  end

  @doc "The fixed message for a catalogued code."
  @spec message(code()) :: String.t()
  for {code, _status, message} <- @catalog do
    def message(unquote(code)), do: unquote(message)
  end

  @doc """
  The error code for an HTTP status.

  Statuses outside the catalog get a code derived from the standard reason
  phrase (405 becomes `"method_not_allowed"`), so every error response has a
  deterministic code.
  """
  @spec code_for_status(100..599) :: code()
  for {code, status, _message} <- @catalog do
    def code_for_status(unquote(status)), do: unquote(code)
  end

  def code_for_status(status) when status in 400..599 do
    status |> Status.reason_atom() |> Atom.to_string()
  rescue
    ArgumentError -> if status >= 500, do: "internal_error", else: "bad_request"
  end

  @doc """
  Builds the error envelope for a status.

  ## Options

    * `:code` - overrides the code derived from `status`
    * `:details` - code-specific details map (default `%{}`)
    * `:request_id` - the request id to echo back (default `nil`)
  """
  @spec envelope(100..599, keyword()) :: envelope()
  def envelope(status, opts \\ []) do
    code = Keyword.get_lazy(opts, :code, fn -> code_for_status(status) end)

    %{
      error: %{
        code: code,
        message: message_for(code, status),
        details: Keyword.get(opts, :details, %{}),
        request_id: Keyword.get(opts, :request_id)
      }
    }
  end

  defp message_for(code, _status) when code in @codes, do: message(code)
  defp message_for(_code, status), do: Status.reason_phrase(status)

  @doc """
  Sends the error envelope for a catalogued `code` and halts the conn.

  Used by plugs and `SimpleFitWeb.FallbackController`. The request id is
  read from the `x-request-id` response header set by `Plug.RequestId`.

  ## Options

    * `:details` - code-specific details map (default `%{}`)
    * `:retry_after` - seconds, sets the `retry-after` header (for
      `rate_limited` and `service_unavailable`)
  """
  @spec send_error(Conn.t(), code(), keyword()) :: Conn.t()
  def send_error(%Conn{} = conn, code, opts \\ []) when code in @codes do
    status = status(code)

    body =
      status
      |> envelope(
        code: code,
        details: Keyword.get(opts, :details, %{}),
        request_id: request_id(conn)
      )
      |> Jason.encode_to_iodata!()

    conn
    |> put_retry_after(opts[:retry_after])
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, body)
    |> Conn.halt()
  end

  defp request_id(conn) do
    case Conn.get_resp_header(conn, "x-request-id") do
      [request_id | _] -> request_id
      [] -> nil
    end
  end

  defp put_retry_after(conn, seconds) when is_integer(seconds) and seconds >= 0,
    do: Conn.put_resp_header(conn, "retry-after", Integer.to_string(seconds))

  defp put_retry_after(conn, _seconds), do: conn
end
