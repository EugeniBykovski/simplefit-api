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
      description: """
      Evidence uploads (logo, files; SF-114): optional. `available: false` (`file_scanning_unavailable`) where
      uploads are off - production until a file scanner or an accepted risk is approved (D-SA09). Documents are
      never scanned for malware: `scanned` is always `false`.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :available,
        :reason,
        :content_types,
        :max_bytes,
        :max_documents,
        :kinds,
        :scanned
      ],
      properties: %{
        available: %Schema{type: :boolean},
        reason: %Schema{type: :string, enum: ["file_scanning_unavailable", nil], nullable: true},
        content_types: %Schema{type: :array, items: %Schema{type: :string}},
        max_bytes: %Schema{type: :integer},
        max_documents: %Schema{type: :integer},
        kinds: %Schema{type: :array, items: %Schema{type: :string}},
        scanned: %Schema{type: :boolean, enum: [false]}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationEvidence do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationEvidence",
      description:
        "A document of the application (no storage key). `pending_upload` until confirmed; `submitted` once part of a submission (then frozen). Never scanned.",
      type: :object,
      additionalProperties: false,
      required: [
        :evidence_id,
        :kind,
        :status,
        :file_name,
        :content_type,
        :byte_size,
        :uploaded_at,
        :submitted,
        :scanned
      ],
      properties: %{
        evidence_id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: ["logo", "brand_deck", "campaign_brief", "other"]},
        status: %Schema{type: :string, enum: ["pending_upload", "uploaded"]},
        file_name: %Schema{type: :string},
        content_type: %Schema{type: :string, enum: ["application/pdf", "image/jpeg", "image/png"]},
        byte_size: %Schema{type: :integer, minimum: 1},
        uploaded_at: %Schema{type: :string, format: :"date-time", nullable: true},
        submitted: %Schema{type: :boolean},
        scanned: %Schema{type: :boolean, enum: [false]}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationChangeRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationChangeRequest",
      description:
        "SimpleFit's open request for changes: only the listed answers can change until the next submission.",
      type: :object,
      additionalProperties: false,
      required: [:reason_code, :fields, :message, :requested_at],
      properties: %{
        reason_code: %Schema{type: :string},
        fields: %Schema{type: :array, items: %Schema{type: :string}},
        message: %Schema{type: :string, description: "Plain text from SimpleFit."},
        requested_at: %Schema{type: :string, format: :"date-time"}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationUpload do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationUpload",
      description: """
      Send the file's bytes with exactly this method, URL and headers before `expires_at`, then confirm the
      document. The URL is a short-lived credential for this one object: never log, store or share it.
      """,
      type: :object,
      additionalProperties: false,
      required: [:method, :url, :headers, :expires_at],
      properties: %{
        method: %Schema{type: :string, enum: ["PUT"]},
        url: %Schema{type: :string, format: :uri},
        headers: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        expires_at: %Schema{type: :string, format: :"date-time"}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationEvidenceRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationEvidenceRequest",
      type: :object,
      additionalProperties: false,
      required: [:expected_revision, :kind, :file_name, :content_type, :byte_size],
      properties: %{
        expected_revision: %Schema{type: :integer, minimum: 1},
        kind: %Schema{type: :string, enum: ["logo", "brand_deck", "campaign_brief", "other"]},
        file_name: %Schema{type: :string, minLength: 1, maxLength: 120},
        content_type: %Schema{type: :string, enum: ["application/pdf", "image/jpeg", "image/png"]},
        byte_size: %Schema{type: :integer, minimum: 1, maximum: 10_485_760}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationEvidenceResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationEvidenceResponse",
      type: :object,
      additionalProperties: false,
      required: [:application, :evidence, :upload],
      properties: %{
        application: SimpleFitWeb.Schemas.SponsorApplication,
        evidence: SimpleFitWeb.Schemas.SponsorApplicationEvidence,
        upload: SimpleFitWeb.Schemas.SponsorApplicationUpload
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationRevisionRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationRevisionRequest",
      type: :object,
      additionalProperties: false,
      required: [:expected_revision],
      properties: %{expected_revision: %Schema{type: :integer, minimum: 1}}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorContactCodeRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorContactCodeRequest",
      type: :object,
      additionalProperties: false,
      required: [:code],
      properties: %{code: %Schema{type: :string, pattern: "^\\d{6}$"}}
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
        :evidence,
        :change_request,
        :sponsor_id,
        :created_at,
        :updated_at
      ],
      properties: %{
        application_id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: Enum.map(Application.statuses(), &Atom.to_string/1)},
        revision: %Schema{type: :integer, minimum: 1},
        answers: SimpleFitWeb.Schemas.SponsorApplicationAnswers,
        contact_email_verified: %Schema{
          type: :boolean,
          description:
            "The contact email was confirmed with a code and hasn't changed since. Grants nothing."
        },
        evidence: %Schema{type: :array, items: SimpleFitWeb.Schemas.SponsorApplicationEvidence},
        change_request: %Schema{
          allOf: [SimpleFitWeb.Schemas.SponsorApplicationChangeRequest],
          type: :object,
          nullable: true
        },
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

defmodule SimpleFitWeb.Schemas.SponsorApplicationReviewResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.Application
  alias SimpleFitWeb.Schemas.SponsorApplicationAnswers

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationReviewResponse",
      description:
        "A submitted sponsor application as a reviewer sees it (SF-114): exactly what was last sent, the open change request and the submitted documents' metadata. No storage keys or file names. SF-116 adds the decision time, the organization an approval created and the status history (who acted: applicant or operator, never which person).",
      type: :object,
      additionalProperties: false,
      required: [:application],
      properties: %{
        application: %Schema{
          type: :object,
          additionalProperties: false,
          required: [
            :application_id,
            :status,
            :revision,
            :submitted_at,
            :latest_submission,
            :change_request,
            :evidence,
            :decided_at,
            :organization,
            :history
          ],
          properties: %{
            viewer_is_party: %Schema{
              type: :boolean,
              description:
                "SF-124, on a read only (absent from action results): whether the reading operator is a party " <>
                  "(the applicant, or a member of the organization its approval created). A party's actions " <>
                  "are refused with `conflict` and `details.target: \"self\"`."
            },
            decided_at: %Schema{type: :string, format: :"date-time", nullable: true},
            organization: %Schema{
              type: :object,
              nullable: true,
              additionalProperties: false,
              description:
                "The organization an approval provisioned (SF-116), or `null`. Approval grants no contract, plan, placement, entitlement or payment.",
              required: [:sponsor_id, :status],
              properties: %{
                sponsor_id: %Schema{type: :string, format: :uuid},
                status: %Schema{type: :string, enum: ["active", "suspended", "closed"]}
              }
            },
            history: %Schema{
              type: :array,
              description: "Status changes, oldest first. Codes only.",
              items: %Schema{
                type: :object,
                additionalProperties: false,
                required: [:event, :actor, :from_status, :to_status, :reason_code, :occurred_at],
                properties: %{
                  event: %Schema{type: :string},
                  actor: %Schema{type: :string, enum: ["applicant", "operator"]},
                  from_status: %Schema{type: :string, nullable: true},
                  to_status: %Schema{type: :string, nullable: true},
                  reason_code: %Schema{type: :string, nullable: true},
                  occurred_at: %Schema{type: :string, format: :"date-time"}
                }
              }
            },
            application_id: %Schema{type: :string, format: :uuid},
            status: %Schema{
              type: :string,
              enum: Enum.map(Application.statuses() -- [:draft], &Atom.to_string/1)
            },
            revision: %Schema{type: :integer, minimum: 1},
            submitted_at: %Schema{type: :string, format: :"date-time", nullable: true},
            latest_submission: %Schema{
              type: :object,
              nullable: true,
              additionalProperties: false,
              required: [
                :submission_id,
                :sequence,
                :submitted_at,
                :policy_version,
                :answers,
                :contact_email_verified,
                :declaration_version,
                :declaration_language
              ],
              properties: %{
                submission_id: %Schema{type: :string, format: :uuid},
                sequence: %Schema{type: :integer, minimum: 1},
                submitted_at: %Schema{type: :string, format: :"date-time"},
                policy_version: %Schema{type: :string},
                answers: SponsorApplicationAnswers,
                contact_email_verified: %Schema{type: :boolean},
                declaration_version: %Schema{type: :string},
                declaration_language: %Schema{type: :string}
              }
            },
            change_request: %Schema{
              allOf: [SimpleFitWeb.Schemas.SponsorApplicationChangeRequest],
              type: :object,
              nullable: true
            },
            evidence: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                additionalProperties: false,
                required: [:evidence_id, :kind, :content_type, :byte_size, :scanned],
                properties: %{
                  evidence_id: %Schema{type: :string, format: :uuid},
                  kind: %Schema{type: :string},
                  content_type: %Schema{type: :string},
                  byte_size: %Schema{type: :integer},
                  scanned: %Schema{type: :boolean, enum: [false]}
                }
              }
            }
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.ClaimSponsorApplicationRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "ClaimSponsorApplicationRequest",
      type: :object,
      additionalProperties: false,
      required: [:reason_code],
      properties: %{
        reason_code: %Schema{type: :string, enum: ["review_started"]},
        expected_revision: %Schema{
          type: :integer,
          minimum: 1,
          description: "Required to execute."
        },
        operation_id: %Schema{type: :string, format: :uuid, description: "Required to execute."}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.RequestSponsorApplicationChangesRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.{ApplicationPolicy, Review}

  OpenApiSpex.schema(
    %{
      title: "RequestSponsorApplicationChangesRequest",
      type: :object,
      additionalProperties: false,
      required: [:reason_code, :fields, :message],
      properties: %{
        reason_code: %Schema{type: :string, enum: Review.change_reasons()},
        fields: %Schema{
          type: :array,
          minItems: 1,
          items: %Schema{
            type: :string,
            enum: Enum.map(ApplicationPolicy.answers(), &Atom.to_string/1)
          },
          description: "The answers the applicant may change."
        },
        message: %Schema{
          type: :string,
          minLength: 1,
          maxLength: 2000,
          description: "Plain text shown to the applicant and sent by email where enabled."
        },
        expected_revision: %Schema{
          type: :integer,
          minimum: 1,
          description: "Required to execute."
        },
        operation_id: %Schema{type: :string, format: :uuid, description: "Required to execute."}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorDecisionRequests do
  @moduledoc false
  alias OpenApiSpex.Schema

  @doc false
  # The body of a decision that needs a confirmation (SF-116): its reason codes.
  def schema(title, reasons, description) do
    %Schema{
      title: title,
      description: description,
      type: :object,
      additionalProperties: false,
      required: [:reason_code],
      properties: %{
        reason_code: %Schema{type: :string, enum: reasons},
        expected_revision: %Schema{
          type: :integer,
          minimum: 1,
          description: "The application's revision. Required to execute."
        },
        operation_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Required to execute; a repeat of the same request changes nothing."
        },
        confirmation_token: %Schema{
          type: :string,
          maxLength: 100,
          description:
            "Required to execute: the one-time confirmation from a preview of exactly this request."
        }
      }
    }
  end
end

defmodule SimpleFitWeb.Schemas.ApproveSponsorApplicationRequest do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFit.Sponsors.Review
  alias SimpleFitWeb.Schemas.SponsorDecisionRequests

  OpenApiSpex.schema(
    SponsorDecisionRequests.schema(
      "ApproveSponsorApplicationRequest",
      Review.decision_reasons(:approve),
      "Approve a sponsor application under review (SF-116)."
    ),
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.RejectSponsorApplicationRequest do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFit.Sponsors.Review
  alias SimpleFitWeb.Schemas.SponsorDecisionRequests

  OpenApiSpex.schema(
    SponsorDecisionRequests.schema(
      "RejectSponsorApplicationRequest",
      Review.decision_reasons(:reject),
      "Reject a sponsor application under review (SF-116). The reason is internal: never shown to the applicant."
    ),
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SuspendSponsorOrganizationRequest do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFit.Sponsors.Review
  alias SimpleFitWeb.Schemas.SponsorDecisionRequests

  OpenApiSpex.schema(
    SponsorDecisionRequests.schema(
      "SuspendSponsorOrganizationRequest",
      Review.decision_reasons(:suspend),
      "Suspend the organization an approved application created (SF-116)."
    ),
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.ReinstateSponsorOrganizationRequest do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFit.Sponsors.Review
  alias SimpleFitWeb.Schemas.SponsorDecisionRequests

  OpenApiSpex.schema(
    SponsorDecisionRequests.schema(
      "ReinstateSponsorOrganizationRequest",
      Review.decision_reasons(:reinstate),
      "Reinstate the suspended organization of an approved application (SF-116)."
    ),
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationQueueResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.Review

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationQueueResponse",
      description:
        "One page of the sponsor application review queue (SF-116), oldest submission first. What the latest submission says about the company; never the contact, the budget or the goals (read the detail, which is audited).",
      type: :object,
      additionalProperties: false,
      required: [:applications, :next_cursor],
      properties: %{
        applications: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            additionalProperties: false,
            required: [
              :application_id,
              :status,
              :revision,
              :submitted_at,
              :decided_at,
              :company_name,
              :country_code,
              :industry,
              :submissions,
              :submitted_documents,
              :change_request_open
            ],
            properties: %{
              application_id: %Schema{type: :string, format: :uuid},
              status: %Schema{
                type: :string,
                enum: Enum.map(Review.queue_statuses(), &Atom.to_string/1)
              },
              revision: %Schema{type: :integer, minimum: 1},
              submitted_at: %Schema{type: :string, format: :"date-time"},
              decided_at: %Schema{type: :string, format: :"date-time", nullable: true},
              company_name: %Schema{type: :string, nullable: true},
              country_code: %Schema{type: :string, nullable: true},
              industry: %Schema{type: :string, nullable: true},
              submissions: %Schema{type: :integer, minimum: 0},
              submitted_documents: %Schema{type: :integer, minimum: 0},
              change_request_open: %Schema{type: :boolean}
            }
          }
        },
        next_cursor: %Schema{
          type: :string,
          nullable: true,
          description: "Opaque; valid only for the same filters, reader and a limited time."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationDocumentDownloadResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationDocumentDownloadResponse",
      description:
        "A short-lived presigned download of one submitted document (SF-116). The URL is a credential: never log, store or share it. It always downloads as an attachment (`application/octet-stream`); documents are never scanned for malware.",
      type: :object,
      additionalProperties: false,
      required: [:download],
      properties: %{
        download: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:method, :url, :expires_at],
          properties: %{
            method: %Schema{type: :string, enum: ["GET"]},
            url: %Schema{type: :string, format: :uri},
            expires_at: %Schema{type: :string, format: :"date-time"}
          }
        }
      }
    },
    struct?: false
  )
end
