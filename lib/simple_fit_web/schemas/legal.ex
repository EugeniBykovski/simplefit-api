defmodule SimpleFitWeb.Schemas.LegalDocumentRef do
  @moduledoc "OpenAPI schema: a legal document version and, when available, its approved text (SF-72)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Legal.Registry

  @languages Registry.languages()

  OpenApiSpex.schema(
    %{
      title: "LegalDocumentRef",
      description: """
      One version of a legal document from the backend's registry (ADR 0022). The metadata is always present;
      the text (`title`, `summary`, `checkbox`, `full`) only when an approved variant exists in exactly the
      requested language, never another language instead. `language` is the language of the text returned (the
      one to echo as `document_language` when accepting); `null` with no text. Render `summary`, `checkbox`
      and `full` as plain text or the Markdown subset (headings, paragraphs, `-` lists); never as HTML.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :available_languages,
        :checkbox,
        :content_sha256,
        :document_id,
        :effective_at,
        :full,
        :language,
        :published_at,
        :requested_language,
        :status,
        :summary,
        :title,
        :version
      ],
      properties: %{
        document_id: %Schema{
          type: :string,
          enum: Registry.document_ids()
        },
        version: %Schema{
          type: :string,
          description: "The version id; one id covers all languages."
        },
        status: %Schema{
          type: :string,
          enum: ["draft", "approved", "published", "superseded", "withdrawn"],
          description: "Only `published` can be accepted; `superseded` is an archive."
        },
        effective_at: %Schema{type: :string, format: :"date-time", nullable: true},
        published_at: %Schema{type: :string, format: :"date-time", nullable: true},
        requested_language: %Schema{
          type: :string,
          enum: @languages,
          nullable: true,
          description: "The language asked for; `null` when none or not a product locale."
        },
        language: %Schema{
          type: :string,
          enum: @languages,
          nullable: true,
          description:
            "The language of the returned text; `null` when no approved variant exists for it."
        },
        available_languages: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: @languages},
          description: "The languages with an approved text of this version."
        },
        content_sha256: %Schema{
          type: :string,
          nullable: true,
          pattern: "^[0-9a-f]{64}$",
          description: "The SHA-256 of the returned text (registry definition)."
        },
        title: %Schema{type: :string, nullable: true},
        summary: %Schema{type: :string, nullable: true, description: "The short in-app text."},
        checkbox: %Schema{
          type: :string,
          nullable: true,
          description: "The confirmation label next to an unticked checkbox."
        },
        full: %Schema{
          type: :string,
          nullable: true,
          description: "The full text (Markdown subset)."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.LegalDocumentResponse do
  @moduledoc "OpenAPI schema: one published legal document (SF-72)."

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "LegalDocumentResponse",
      type: :object,
      additionalProperties: false,
      required: [:document],
      properties: %{document: SimpleFitWeb.Schemas.LegalDocumentRef}
    },
    struct?: false
  )
end
