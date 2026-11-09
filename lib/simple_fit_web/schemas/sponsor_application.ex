defmodule SimpleFitWeb.Schemas.SponsorApplicationSchemas do
  @moduledoc false
  # Shared property definitions, from the one policy the backend validates against.

  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.ApplicationPolicy

  @doc false
  def answers(nullable?) do
    s = fn schema -> if nullable?, do: %{schema | nullable: true}, else: schema end
    codes = fn list -> %Schema{type: :string, enum: list} end

    %{
      company_name: s.(%Schema{type: :string, minLength: 1, maxLength: 200}),
      website: s.(%Schema{type: :string, maxLength: 200, pattern: "^https://\\S+$"}),
      country_code:
        s.(%Schema{type: :string, pattern: "^[A-Z]{2}$", description: "ISO 3166-1 alpha-2."}),
      industry: s.(codes.(ApplicationPolicy.industries())),
      contact_full_name: s.(%Schema{type: :string, minLength: 1, maxLength: 120}),
      contact_position: s.(%Schema{type: :string, minLength: 1, maxLength: 120}),
      contact_email:
        s.(%Schema{
          type: :string,
          maxLength: 254,
          description:
            "A work address to discuss the application. Never verified; grants nothing."
        }),
      contact_phone:
        s.(%Schema{type: :string, pattern: "^\\+[1-9][0-9]{6,14}$", description: "E.164."}),
      interests: %Schema{type: :array, maxItems: 9, items: codes.(ApplicationPolicy.interests())},
      market_scope: s.(codes.(ApplicationPolicy.scopes())),
      market_countries: %Schema{
        type: :array,
        maxItems: 50,
        items: %Schema{type: :string, pattern: "^[A-Z]{2}$"}
      },
      market_cities: %Schema{
        type: :array,
        maxItems: 20,
        items: %Schema{type: :string, minLength: 1, maxLength: 80}
      },
      budget_band:
        s.(%Schema{
          type: :string,
          enum: Enum.map(ApplicationPolicy.budget_bands(), & &1.code),
          description:
            "An annual estimate in EUR excluding VAT. Not an amount, price, commitment or verified figure."
        }),
      goals: s.(%Schema{type: :string, minLength: 1, maxLength: 2000})
    }
  end
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationAnswers do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFit.Sponsors.ApplicationPolicy
  alias SimpleFitWeb.Schemas.SponsorApplicationSchemas

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationAnswers",
      description: "The applicant's answers (SP1-SP6). `null` or `[]` where not answered yet.",
      type: :object,
      additionalProperties: false,
      required: Enum.sort(ApplicationPolicy.answers()),
      properties: SponsorApplicationSchemas.answers(true)
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationSaveRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SponsorApplicationSchemas

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationSaveRequest",
      description: """
      Any subset of the answers; only those change, each validated now (an invalid save changes nothing). `null`
      clears an answer. Starting an application needs at least one non-blank answer and `client_request_id`;
      every later save needs `expected_revision`.
      """,
      type: :object,
      additionalProperties: false,
      properties:
        Map.merge(SponsorApplicationSchemas.answers(true), %{
          expected_revision: %Schema{type: :integer, minimum: 1},
          client_request_id: %Schema{type: :string, format: :uuid}
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationSubmitRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationSubmitRequest",
      type: :object,
      additionalProperties: false,
      required: [
        :expected_revision,
        :client_request_id,
        :declaration_accepted,
        :declaration_version,
        :declaration_language
      ],
      properties: %{
        expected_revision: %Schema{type: :integer, minimum: 1},
        client_request_id: %Schema{
          type: :string,
          format: :uuid,
          description: "One per submit attempt; a repeat with the same request answers the same."
        },
        declaration_accepted: %Schema{type: :boolean, enum: [true]},
        declaration_version: %Schema{
          type: :string,
          description: "The published declaration version from `declaration.version`."
        },
        declaration_language: %Schema{
          type: :string,
          description: "One of `declaration.languages`."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationDeclaration do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationDeclaration",
      description:
        "The declaration a submission must accept: the published legal registry version. `available: false` while counsel hasn't published one; submission is then unavailable.",
      type: :object,
      additionalProperties: false,
      required: [:available, :document_id, :version, :languages],
      properties: %{
        available: %Schema{type: :boolean},
        document_id: %Schema{type: :string},
        version: %Schema{type: :string, nullable: true},
        languages: %Schema{type: :array, items: %Schema{type: :string}}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationUploads do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationUploads",
      description:
        "Uploads (logo, files) are unavailable until a file scanner is approved (D-SA09). Optional.",
      type: :object,
      additionalProperties: false,
      required: [:available, :reason],
      properties: %{
        available: %Schema{type: :boolean, enum: [false]},
        reason: %Schema{type: :string, enum: ["file_scanning_unavailable"]}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationSubmissionSummary do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationSubmissionSummary",
      type: :object,
      additionalProperties: false,
      required: [:submission_id, :sequence, :submitted_at, :policy_version],
      properties: %{
        submission_id: %Schema{type: :string, format: :uuid},
        sequence: %Schema{type: :integer, minimum: 1},
        submitted_at: %Schema{type: :string, format: :"date-time"},
        policy_version: %Schema{type: :string}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplication do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.{Application, ApplicationPolicy}

  OpenApiSpex.schema(
    %{
      title: "SponsorApplication",
      description: """
      The viewer's sponsor application. It grants nothing in any status: no organization, membership,
      agreement, payment or verification. `sponsor_id` appears only once an approval created an organization.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :application_id,
        :status,
        :revision,
        :answers,
        :contact_email_verified,
        :missing_fields,
        :allowed_actions,
        :submit_blockers,
        :submitted_at,
        :submissions,
        :declaration,
        :uploads,
        :sponsor_id,
        :created_at,
        :updated_at
      ],
      properties: %{
        application_id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: Enum.map(Application.statuses(), &Atom.to_string/1)},
        revision: %Schema{type: :integer, minimum: 1},
        answers: SimpleFitWeb.Schemas.SponsorApplicationAnswers,
        contact_email_verified: %Schema{type: :boolean, enum: [false]},
        missing_fields: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: Enum.map(ApplicationPolicy.answers(), &Atom.to_string/1)
          },
          description: "Answers a submission still needs, in step order."
        },
        allowed_actions: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ["edit", "submit"]}
        },
        submit_blockers: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ["incomplete", "declaration_unavailable"]},
          description: "Why `submit` isn't allowed now while editing is."
        },
        submitted_at: %Schema{type: :string, format: :"date-time", nullable: true},
        submissions: %Schema{
          type: :array,
          items: SimpleFitWeb.Schemas.SponsorApplicationSubmissionSummary
        },
        declaration: SimpleFitWeb.Schemas.SponsorApplicationDeclaration,
        uploads: SimpleFitWeb.Schemas.SponsorApplicationUploads,
        sponsor_id: %Schema{type: :string, format: :uuid, nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationResponse",
      type: :object,
      additionalProperties: false,
      required: [:application],
      properties: %{application: SimpleFitWeb.Schemas.SponsorApplication}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationSubmissionResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationSubmissionResponse",
      description: "Exactly what one submission sent. Immutable.",
      type: :object,
      additionalProperties: false,
      required: [:submission],
      properties: %{
        submission: %Schema{
          type: :object,
          additionalProperties: false,
          required: [
            :submission_id,
            :sequence,
            :submitted_at,
            :policy_version,
            :answers,
            :declaration_version,
            :declaration_language
          ],
          properties: %{
            submission_id: %Schema{type: :string, format: :uuid},
            sequence: %Schema{type: :integer, minimum: 1},
            submitted_at: %Schema{type: :string, format: :"date-time"},
            policy_version: %Schema{type: :string},
            answers: SimpleFitWeb.Schemas.SponsorApplicationAnswers,
            declaration_version: %Schema{type: :string},
            declaration_language: %Schema{type: :string}
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationPolicyResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.ApplicationPolicy

  @codes %Schema{type: :array, items: %Schema{type: :string}}

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationPolicyResponse",
      description:
        "What the backend accepts and what a submission needs (codes; clients translate). Versioned.",
      type: :object,
      additionalProperties: false,
      required: [:policy],
      properties: %{
        policy: %Schema{
          type: :object,
          additionalProperties: false,
          required: [
            :version,
            :steps,
            :required,
            :industries,
            :interests,
            :scopes,
            :budget_bands,
            :uploads,
            :declaration
          ],
          properties: %{
            version: %Schema{type: :string, example: ApplicationPolicy.version()},
            steps: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                additionalProperties: false,
                required: [:step, :fields],
                properties: %{step: %Schema{type: :string}, fields: @codes}
              }
            },
            required: @codes,
            industries: @codes,
            interests: @codes,
            scopes: @codes,
            budget_bands: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                additionalProperties: false,
                required: [:code, :currency, :min, :max],
                properties: %{
                  code: %Schema{type: :string},
                  currency: %Schema{type: :string, enum: ["EUR"]},
                  min: %Schema{
                    type: :integer,
                    nullable: true,
                    description: "Whole euros per year."
                  },
                  max: %Schema{
                    type: :integer,
                    nullable: true,
                    description: "Whole euros per year."
                  }
                }
              }
            },
            uploads: SimpleFitWeb.Schemas.SponsorApplicationUploads,
            declaration: SimpleFitWeb.Schemas.SponsorApplicationDeclaration
          }
        }
      }
    },
    struct?: false
  )
end
