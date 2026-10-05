defmodule SimpleFitWeb.FallbackController do
  @moduledoc """
  Maps `{:error, reason}` results from domain contexts to the API error
  envelope (`action_fallback SimpleFitWeb.FallbackController`). See
  docs/architecture/adr/0003-api-versioning-and-errors.md.

  | Context result | Public code |
  | --- | --- |
  | `{:error, %Ecto.Changeset{}}` | `validation_error`, with `fields` and `field_codes` |
  | `{:error, :not_found}` | `not_found` |
  | `{:error, :forbidden}` | `forbidden` |
  | `{:error, :conflict}` | `conflict` |
  | `{:error, provider_reason}` retryable (`:rate_limited`, `:timeout`, `:unavailable`) | `service_unavailable` |
  | `{:error, provider_reason}` other (`:unauthorized`, `:invalid_request`, `:configuration_error`) | `internal_error` |
  | anything else | `internal_error` |

  `SimpleFit.Provider` reasons describe *our* call to a vendor (`:unauthorized`
  means the vendor rejected SimpleFit's credentials), so they never become a
  client-facing 401 or 429. Client authentication and rate limiting send
  `unauthorized` / `rate_limited` from their plugs with
  `SimpleFitWeb.APIError.send_error/3`.

  Internal reasons are logged with the request id; only the catalogued code
  and message reach the client.
  """

  use SimpleFitWeb, :controller

  require Logger

  alias SimpleFitWeb.{APIError, ChangesetErrors}

  @provider_reasons [
    :invalid_request,
    :unauthorized,
    :rate_limited,
    :timeout,
    :unavailable,
    :configuration_error
  ]

  @spec call(Plug.Conn.t(), {:error, term()}) :: Plug.Conn.t()
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    APIError.send_error(conn, "validation_error", details: ChangesetErrors.details(changeset))
  end

  def call(conn, {:error, reason}) when reason in [:not_found, :forbidden, :conflict] do
    APIError.send_error(conn, Atom.to_string(reason))
  end

  def call(conn, {:error, reason}) when reason in @provider_reasons do
    Logger.warning("provider failure surfaced to a request", reason: reason)

    if SimpleFit.Provider.retryable?(reason) do
      APIError.send_error(conn, "service_unavailable")
    else
      APIError.send_error(conn, "internal_error")
    end
  end

  def call(conn, {:error, reason}) do
    Logger.error("unhandled error result: #{inspect(reason, limit: 20, printable_limit: 200)}")
    APIError.send_error(conn, "internal_error")
  end
end
