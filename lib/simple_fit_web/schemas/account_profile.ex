defmodule SimpleFitWeb.Schemas.AccountProfileUpdateRequest do
  @moduledoc "OpenAPI schema: save shared account registration progress (ADR 0016)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "AccountProfileUpdateRequest",
      description: """
      Any subset of the registration basics and consent decisions. Omitted fields are unchanged. Nothing is
      required while registration is in progress. A save with nothing to persist creates nothing.
      """,
      type: :object,
      additionalProperties: false,
      properties: %{
        full_name: %Schema{
          type: :string,
          nullable: true,
          minLength: 1,
          maxLength: 200,
          description: """
          The person's full name (account level; not a role profile's public display name). Trimmed;
          `null` clears it while registration is in progress. After completion it can be changed, not cleared.
          """,
          example: "Alex Kowalski"
        },
        date_of_birth: %Schema{
          type: :string,
          format: :date,
          description: """
          A real calendar date, not in the future, at least 16 years ago by calendar date (`too_young`
          otherwise). Cannot be changed once registration is complete (`immutable`).
          """,
          example: "2000-05-17"
        },
        accept_terms: %Schema{
          type: :boolean,
          enum: [true],
          description:
            "Accepts the current Terms of Service version. Only `true`: required consents cannot be withdrawn here (`must_be_accepted`)."
        },
        accept_privacy: %Schema{
          type: :boolean,
          enum: [true],
          description:
            "Accepts the current Privacy Policy version. Only `true` (`must_be_accepted`)."
        },
        product_news: %Schema{
          type: :boolean,
          description:
            "Optional product news by email: `true` subscribes, `false` withdraws. Never required to complete registration."
        }
      },
      example: %{
        full_name: "Alex Kowalski",
        accept_terms: true,
        accept_privacy: true,
        product_news: false
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.AccountProfileResponse do
  @moduledoc "OpenAPI schema: the authenticated user's shared account registration."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @legal %Schema{
    type: :object,
    required: [:accepted, :accepted_version, :accepted_at, :current_version, :current],
    additionalProperties: false,
    properties: %{
      accepted: %Schema{type: :boolean, description: "Whether any version has been accepted."},
      accepted_version: %Schema{
        type: :string,
        nullable: true,
        description: "The latest accepted version."
      },
      accepted_at: %Schema{type: :string, format: :"date-time", nullable: true},
      current_version: %Schema{type: :string, description: "The version currently in force."},
      current: %Schema{
        type: :boolean,
        description: """
        Whether the current version has been accepted. Initial registration completion requires it. A completed
        registration stays complete when a later version makes this `false`; it only signals that a re-consent is
        due (a future flow).
        """
      }
    }
  }

  OpenApiSpex.schema(
    %{
      title: "AccountProfileResponse",
      description: """
      Always returned, also before registration has started (`status: not_started`, every requirement
      missing), so a client can render the shared Basics & Consent step from this response alone.
      """,
      type: :object,
      required: [:account_profile],
      additionalProperties: false,
      properties: %{
        account_profile: %Schema{
          type: :object,
          required: [:registration, :full_name, :date_of_birth, :consents, :product_news],
          additionalProperties: false,
          properties: %{
            registration: %Schema{
              type: :object,
              required: [:status, :completed_at, :missing_requirements],
              additionalProperties: false,
              properties: %{
                status: %Schema{
                  type: :string,
                  enum: ["not_started", "in_progress", "complete"],
                  description: """
                  `not_started`: nothing saved yet. `in_progress`: progress saved, not completed. `complete`:
                  completion recorded by `completeAccountRegistration`; permanent, also after a later legal
                  document version change.
                  """
                },
                completed_at: %Schema{type: :string, format: :"date-time", nullable: true},
                missing_requirements: %Schema{
                  type: :array,
                  items: %Schema{
                    type: :string,
                    enum: ["full_name", "date_of_birth", "terms", "privacy"]
                  },
                  description: """
                  What initial completion still needs, in form order: empty fields, and required consents not
                  accepted at their current version. Always empty once complete, also after a document version
                  change (see `consents.*.current`).
                  """
                }
              }
            },
            full_name: %Schema{type: :string, nullable: true},
            date_of_birth: %Schema{type: :string, format: :date, nullable: true},
            consents: %Schema{
              type: :object,
              required: [:terms, :privacy],
              additionalProperties: false,
              properties: %{terms: @legal, privacy: @legal}
            },
            product_news: %Schema{
              type: :object,
              required: [:subscribed, :updated_at],
              additionalProperties: false,
              properties: %{
                subscribed: %Schema{type: :boolean},
                updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
              }
            }
          }
        }
      },
      example: %{
        account_profile: %{
          registration: %{
            status: "in_progress",
            completed_at: nil,
            missing_requirements: ["date_of_birth"]
          },
          full_name: "Alex Kowalski",
          date_of_birth: nil,
          consents: %{
            terms: %{
              accepted: true,
              accepted_version: "terms-v1",
              accepted_at: "2026-10-09T10:00:00.000000Z",
              current_version: "terms-v1",
              current: true
            },
            privacy: %{
              accepted: true,
              accepted_version: "privacy-v1",
              accepted_at: "2026-10-09T10:00:00.000000Z",
              current_version: "privacy-v1",
              current: true
            }
          },
          product_news: %{subscribed: false, updated_at: nil}
        }
      }
    },
    struct?: false
  )
end
