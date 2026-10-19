defmodule SimpleFitWeb.LegalDocumentController do
  @moduledoc """
  Published legal documents for the public pages (SF-72; ADR 0022): the
  current version of a document or a named archived one, in one language.
  No sign-in. Only `published` and `superseded` versions exist here; drafts,
  approved-but-unpublished and withdrawn versions answer `404`, as does
  everything while no document is published.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Parameter, Schema}
  alias SimpleFit.Legal
  alias SimpleFit.Legal.Registry
  alias SimpleFitWeb.{ApiSpec, Schemas}

  action_fallback SimpleFitWeb.FallbackController

  tags ["Legal"]

  @document_id %Parameter{
    name: :document_id,
    in: :path,
    required: true,
    description: "The document.",
    schema: %Schema{type: :string, enum: Registry.document_ids()}
  }
  @language %Parameter{
    name: :language,
    in: :query,
    required: false,
    description: """
    The language to read the text in. Without an approved variant in that language the text fields are `null`
    and `available_languages` lists the approved ones (never another language instead).
    """,
    schema: %Schema{type: :string}
  }
  @responses [
    ok: {"The document", "application/json", Schemas.LegalDocumentResponse},
    not_found: ApiSpec.error_response("not_found"),
    internal_server_error: ApiSpec.error_response("internal_error")
  ]

  operation :show,
    operation_id: "getLegalDocument",
    summary: "The current version of a legal document",
    description:
      "The `published` version of a document. `not_found` while none is published (the current state).",
    parameters: [@document_id, @language],
    responses: @responses

  def show(conn, %{"document_id" => id} = params),
    do: render_document(conn, Legal.public_document(id, :current, params["language"]))

  operation :show_version,
    operation_id: "getLegalDocumentVersion",
    summary: "One version of a legal document",
    description:
      "A `published` or `superseded` version (an archive whose text never changes). Anything else: `not_found`.",
    parameters: [
      @document_id,
      %Parameter{
        name: :version,
        in: :path,
        required: true,
        description: "The version id.",
        schema: %Schema{type: :string}
      },
      @language
    ],
    responses: @responses

  def show_version(conn, %{"document_id" => id, "version" => version} = params),
    do: render_document(conn, Legal.public_document(id, version, params["language"]))

  defp render_document(conn, {:ok, document}) do
    conn
    |> put_resp_header("cache-control", "no-cache")
    |> put_view(SimpleFitWeb.LegalJSON)
    |> render(:show, document: document)
  end

  defp render_document(_conn, {:error, :not_found}), do: {:error, :not_found}
end
