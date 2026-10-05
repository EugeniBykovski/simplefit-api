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
        * Product resources will be served under `/api/v1`. Operational endpoints live under `/api`.
        """
      },
      servers: [%Server{url: "/", description: "The host serving this document"}],
      tags: [%Tag{name: "System", description: "Operational endpoints."}],
      paths: Paths.from_router(SimpleFitWeb.Router),
      components: %Components{
        schemas: %{},
        responses: error_responses(),
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: """
            Bearer access token. Reserved for the authentication ticket: no endpoint requires it yet.
            """
          }
        }
      }
    }
    |> OpenApiSpex.add_schemas([
      Schemas.Error,
      Schemas.ErrorResponse,
      Schemas.ValidationErrorDetails
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
