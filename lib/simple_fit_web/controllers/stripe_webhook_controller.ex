defmodule SimpleFitWeb.StripeWebhookController do
  @moduledoc """
  Stripe webhooks (SF-102). Authenticated by the `Stripe-Signature` header
  over the exact raw body (`SimpleFitWeb.RawBody`), never by a session. The
  rules live in `SimpleFit.Billing.Webhooks`: a `2xx` is answered only once
  the event is durably in the inbox; processing is asynchronous.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Parameter, Schema}
  alias SimpleFit.Billing.Webhooks
  alias SimpleFitWeb.{APIError, ApiSpec, RawBody, Schemas}

  tags ["Payment provider webhooks"]

  operation :create,
    operation_id: "receiveStripeWebhook",
    summary: "Receive a Stripe event",
    description: """
    Called by Stripe only. The signature is verified against the raw body with the endpoint's secret and a
    five-minute timestamp tolerance; the event must be of the configured mode and SimpleFit's own account. The
    event id and type are stored once (a repeated delivery answers `duplicate: true` and changes nothing) and
    the object is re-read from Stripe asynchronously: the event body is never applied.

    * `bad_request` - missing, malformed, expired or invalid signature, or an event that is not acceptable here
      (other mode, a connected account's event). No detail is disclosed.
    * `service_unavailable` - payments are disabled here or the inbox could not be written; Stripe retries.
    """,
    parameters: [
      %Parameter{
        name: :"stripe-signature",
        in: :header,
        required: true,
        description: "Stripe's signature header (`t=...,v1=...`).",
        schema: %Schema{type: :string}
      }
    ],
    request_body:
      {"A Stripe event", "application/json",
       %Schema{type: :object, additionalProperties: true, description: "A Stripe Event object."},
       required: true},
    responses: [
      ok: {"Recorded", "application/json", Schemas.StripeWebhookAck},
      bad_request: ApiSpec.error_response("bad_request"),
      internal_server_error: ApiSpec.error_response("internal_error"),
      service_unavailable: ApiSpec.error_response("service_unavailable")
    ]

  def create(conn, _params) do
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case Webhooks.ingest(RawBody.get(conn), signature, conn.body_params) do
      {:ok, outcome} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{received: true, duplicate: outcome == :duplicate})

      {:error, reason} when reason in [:invalid_signature, :invalid_event] ->
        APIError.send_error(conn, "bad_request")

      {:error, _disabled_or_storage} ->
        APIError.send_error(conn, "service_unavailable", retry_after: 60)
    end
  end
end
