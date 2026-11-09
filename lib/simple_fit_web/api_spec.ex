defmodule SimpleFitWeb.ApiSpec do
  @moduledoc """
  The SimpleFit OpenAPI 3 contract (code-first).

  Operations are declared next to the controllers that implement them
  (`open_api_spex` `operation/2`) and collected from the router. This module
  adds document-level metadata, tags, reusable error responses and security
  schemes.

  The committed artifact `openapi/simplefit.api.json` is generated from this
  module with `mix openapi.gen` and verified with `mix openapi.check`. Never
  edit the artifact by hand. See docs/architecture/adr/0002-openapi-strategy.md.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, MediaType, OpenApi, Paths, Reference}
  alias OpenApiSpex.{Response, SecurityScheme, Server, Tag}
  alias SimpleFitWeb.APIError
  alias SimpleFitWeb.Schemas

  @artifact_path "openapi/simplefit.api.json"
  @version Mix.Project.config()[:version]

  @doc "Path of the committed OpenAPI artifact, relative to the project root."
  @spec artifact_path() :: String.t()
  def artifact_path, do: @artifact_path

  @impl OpenApi
  def spec do
    %OpenApi{
      openapi: "3.0.3",
      info: %Info{
        title: "SimpleFit API",
        version: @version,
        description: """
        Backend API for SimpleFit Boxing: the operating system and professional network for boxing.

        ## Conventions

        * JSON request and response bodies (`application/json`) only.
        * Errors use a single envelope (`ErrorResponse`) with a stable machine-readable `code`;
          validation errors add per-field reason codes (`ValidationErrorDetails`). Clients branch
          on codes, never on human-readable messages.
        * Browser clients must be on the API's CORS allow-list (explicit origins, no wildcard).
        * Every response carries an `x-request-id` header; error bodies echo it as `request_id`.
        * Product resources will be served under `/api/v1`. Operational, session (`/api/auth`) and viewer
          (`/api/me`) endpoints live under `/api`.
        * Authenticated endpoints take `Authorization: Bearer <access_token>`; see `SessionTokens`.
        """
      },
      servers: [%Server{url: "/", description: "The host serving this document"}],
      tags: [
        %Tag{name: "Auth", description: "SimpleFit sessions and the authenticated viewer."},
        %Tag{
          name: "Account",
          description:
            "Shared account registration (basics and consents) and the account's verified email identities, for every user."
        },
        %Tag{
          name: "Fighter profile",
          description: "The viewer's fighter profile and resumable Fighter onboarding."
        },
        %Tag{
          name: "Coach profile",
          description:
            "The viewer's coach profile and resumable Coach onboarding, independent of the fighter profile."
        },
        %Tag{
          name: "Entry",
          description: "Where an authenticated user goes next, as a semantic destination."
        },
        %Tag{
          name: "First run",
          description:
            "One-time first-run experiences, such as product tours, and how the viewer left them."
        },
        %Tag{
          name: "Coaching",
          description:
            "Coach–Fighter relationships: a coach's fighters as disclosed and a fighter's coaches (ADR 0021)."
        },
        %Tag{
          name: "Training",
          description:
            "Training sessions a coach assigns to a fighter of an active relationship, and the fighter's own (ADR 0023)."
        },
        %Tag{
          name: "Gyms",
          description:
            "Gyms (the tenant) and the viewer's staff memberships; every gym-scoped path names the gym (ADR 0026)."
        },
        %Tag{
          name: "Gym staff",
          description:
            "A gym's staff roster, role changes and staff invitations, and the recipient's own invitations " <>
              "(ADR 0026, SF-93). Separate from Coach–Fighter invitations."
        },
        %Tag{
          name: "Gym members",
          description:
            "A gym's members (participants): join codes and requests, auto-approval, member invitations (E07), " <>
              "the roster, leaving and removal, the member-list dry run, and the member's own memberships and " <>
              "invitations (ADR 0026, SF-95). Separate from staff and Coach–Fighter relationships."
        },
        %Tag{
          name: "Gym timetable",
          description:
            "A gym's venues, class templates, bounded weekly series and class occurrences, in IANA zones with " <>
              "DST-safe wall-clock rules and database-enforced venue and instructor conflicts (ADR 0026, " <>
              "SF-97). Separate from Coach–Fighter training sessions. Bookings and check-ins are " <>
              "\"Gym bookings\"."
        },
        %Tag{
          name: "Gym bookings",
          description:
            "Places in gym classes: a member's own bookings of their gym's classes, staff booking for " <>
              "members, class rosters and manual check-ins, with database-enforced capacity and " <>
              "idempotent requests (ADR 0026, SF-99). No waitlist, payment, entitlement or penalty."
        },
        %Tag{
          name: "SimpleFit plans",
          description:
            "SimpleFit's SaaS plans for gyms, a gym's subscription intent and cancellation, and its " <>
              "backend-owned entitlements (ADR 0026, SF-101); its Stripe-backed billing (SF-102): hosted " <>
              "checkout, the Customer Portal, reconciled payment state and Stripe invoices. Prices are " <>
              "immutable versions in integer minor units, rendered as decimal strings. An intent grants " <>
              "nothing; only a paid Stripe invoice reconciled by the backend activates. No gym feature is gated."
        },
        %Tag{
          name: "Gym member products",
          description:
            "A gym's own products for its members (single visits, class packs, unlimited periods) with " <>
              "immutable versions and append-only prices, and its members' product subscription intents " <>
              "(ADR 0026, SF-101). Separate from SimpleFit plans. No payment, credit debit or booking rule."
        },
        %Tag{
          name: "Gym verification",
          description:
            "A gym's business verification (SF-103): the owner's application, documents in private storage " <>
              "and submission; only SimpleFit operators decide, outside the API. And the gym's go-live " <>
              "readiness, derived from its records. Separate from gym setup, SimpleFit plans and Stripe; " <>
              "nothing is published (no public gym surface is approved)."
        },
        %Tag{
          name: "Sponsor applications",
          description:
            "The viewer's own sponsor application (SF-113): resumable drafts, server-owned validation, " <>
              "explicit submission with an immutable copy of what was sent. An application grants nothing."
        },
        %Tag{
          name: "Sponsors",
          description:
            "Sponsor organizations (SF-112): the viewer's own memberships, and each organization's details, " <>
              "members and contacts, authorized by the viewer's active membership of that organization. " <>
              "Read-only: organizations are provisioned internally on approval, never created here."
        },
        %Tag{
          name: "Platform operators",
          description:
            "Platform operators (SF-110): the viewer's operator state, WebAuthn security keys, the " <>
              "session-bound key check, operator administration and the operator audit log. Everything " <>
              "answers `not_found` to an account without a usable operator."
        },
        %Tag{
          name: "Payment provider webhooks",
          description:
            "Inbound Stripe webhooks (SF-102), authenticated by the Stripe-Signature header over the raw body, " <>
              "never by a session. Not for clients."
        },
        %Tag{
          name: "Legal",
          description: "Published legal documents (versioned, per language; ADR 0022)."
        },
        %Tag{name: "System", description: "Operational endpoints."}
      ],
      paths: Paths.from_router(SimpleFitWeb.Router),
      components: %Components{
        schemas: %{},
        responses: error_responses(),
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: """
            SimpleFit access token (`sfa_...`) from `SessionTokens`, valid for 15 minutes and only while
            its session is active. Refresh tokens and provider tokens are never accepted here.
            """
          },
          "refreshCookie" => %SecurityScheme{
            type: "apiKey",
            in: "cookie",
            name: "__Secure-sf_refresh",
            description: """
            Web refresh token: `HttpOnly; Secure; SameSite=Strict; Path=/api/auth` cookie, sent only to
            `/api/auth/*`. Requests using it must carry an allow-listed `Origin` and `x-simplefit-csrf: 1`.
            """
          }
        }
      }
    }
    |> OpenApiSpex.add_schemas([
      Schemas.Error,
      Schemas.ErrorResponse,
      Schemas.ValidationErrorDetails,
      Schemas.SessionTokens,
      Schemas.RefreshSessionRequest,
      Schemas.CurrentUserResponse
    ])
    |> OpenApiSpex.resolve_schema_modules()
  end

  @doc """
  Reference to a reusable error response, for use in controller operations:

      responses: [
        ok: {"User", "application/json", Schemas.User},
        not_found: SimpleFitWeb.ApiSpec.error_response("not_found")
      ]
  """
  @spec error_response(APIError.code()) :: Reference.t()
  def error_response(code) when is_binary(code) do
    %Reference{"$ref": "#/components/responses/#{response_name(code)}"}
  end

  @doc """
  Encodes the spec as the canonical artifact: pretty-printed JSON with
  recursively sorted object keys and a trailing newline, so output is
  byte-for-byte deterministic and diffs stay readable.
  """
  @spec to_json(OpenApi.t()) :: String.t()
  def to_json(%OpenApi{} = spec \\ spec()) do
    spec
    |> OpenApi.to_map(vendor_extensions: false)
    |> sort_keys()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, sort_keys(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(value), do: value

  defp error_responses do
    Map.new(APIError.codes(), fn code ->
      status = APIError.status(code)

      response = %Response{
        description: "#{status} #{APIError.message(code)}",
        content: %{
          "application/json" => %MediaType{
            schema: %Reference{"$ref": "#/components/schemas/ErrorResponse"},
            example:
              APIError.envelope(status,
                code: code,
                details: example_details(code),
                request_id: Schemas.Examples.request_id()
              )
          }
        }
      }

      {response_name(code), response}
    end)
  end

  defp example_details("validation_error"), do: Schemas.ValidationErrorDetails.schema().example

  defp example_details(_code), do: %{}

  defp response_name(code), do: Macro.camelize(code)
end
