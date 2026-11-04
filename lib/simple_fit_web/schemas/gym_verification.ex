defmodule SimpleFitWeb.Schemas.GymVerificationApplication do
  @moduledoc "OpenAPI schema: the business details of a verification application (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @text %Schema{type: :string, nullable: true}
  @timestamp %Schema{type: :string, format: :"date-time", nullable: true}

  OpenApiSpex.schema(
    %{
      title: "GymVerificationApplication",
      description: """
      The business details the owner declared, as stored. Visible only to the gym's owner (and to SimpleFit's
      operators, outside the API). Frozen from submission until changes are requested.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :id,
        :revision,
        :policy_version,
        :legal_name,
        :registration_country,
        :registration_number,
        :address_line,
        :postal_code,
        :city,
        :website,
        :submitted_at,
        :decided_at,
        :created_at,
        :updated_at
      ],
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        revision: %Schema{
          type: :integer,
          minimum: 1,
          description:
            "Bumped by every owner change (details and documents). Send it back with the next change."
        },
        policy_version: %Schema{
          type: :string,
          description: "The requirement policy the application was created under."
        },
        legal_name: %{@text | description: "The business's registered legal name."},
        registration_country: %Schema{
          type: :string,
          nullable: true,
          pattern: "^[A-Z]{2}$",
          description: "ISO 3166-1 alpha-2 code of the country of registration."
        },
        registration_number: %{@text | description: "The business registration identifier."},
        address_line: %{@text | description: "The registered address (street and number)."},
        postal_code: @text,
        city: @text,
        website: %Schema{type: :string, format: :uri, nullable: true},
        submitted_at: %{
          @timestamp
          | description: "The latest submission; `null` before the first."
        },
        decided_at: %{@timestamp | description: "The latest decision; `null` before the first."},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVerificationEvidence do
  @moduledoc "OpenAPI schema: a document of a verification application (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.VerificationPolicy

  OpenApiSpex.schema(
    %{
      title: "GymVerificationEvidence",
      description: """
      A document in SimpleFit's private storage. Its storage location is never exposed and there is no public or
      owner download: only SimpleFit's operators open documents, through short-lived links recorded in the
      application's history.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :id,
        :kind,
        :status,
        :file_name,
        :content_type,
        :byte_size,
        :uploaded_at,
        :submitted,
        :created_at
      ],
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        kind: %Schema{
          type: :string,
          enum: Enum.map(VerificationPolicy.kinds(), &Atom.to_string/1)
        },
        status: %Schema{
          type: :string,
          enum: ["pending_upload", "uploaded"],
          description: """
          `pending_upload`: announced; upload it, then confirm it (`confirmGymVerificationEvidence`). `uploaded`:
          the server read the stored object and it matches the announced type and size.
          """
        },
        file_name: %Schema{
          type: :string,
          description: "The base name the owner gave (display only)."
        },
        content_type: %Schema{type: :string, enum: VerificationPolicy.content_types()},
        byte_size: %Schema{type: :integer, minimum: 1, maximum: VerificationPolicy.max_bytes()},
        uploaded_at: %Schema{type: :string, format: :"date-time", nullable: true},
        submitted: %Schema{
          type: :boolean,
          description: "Part of a submission: frozen (it can no longer be removed)."
        },
        created_at: %Schema{type: :string, format: :"date-time"}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVerificationDecision do
  @moduledoc "OpenAPI schema: the latest operator decision on an application (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.VerificationPolicy

  OpenApiSpex.schema(
    %{
      title: "GymVerificationDecision",
      description:
        "The latest decision of a SimpleFit operator: what and why (a code), never who or free text.",
      type: :object,
      additionalProperties: false,
      required: [:decision, :reason_code, :decided_at],
      properties: %{
        decision: %Schema{
          type: :string,
          enum: ["approved", "rejected", "changes_requested", "revoked"]
        },
        reason_code: %Schema{
          type: :string,
          nullable: true,
          enum: Enum.map(VerificationPolicy.all_reasons(), &Atom.to_string/1) ++ [nil],
          description: "Why; `null` for an approval."
        },
        decided_at: %Schema{type: :string, format: :"date-time"}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVerificationRequirements do
  @moduledoc "OpenAPI schema: the requirements an application is checked against (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.VerificationPolicy

  @fields Enum.map(VerificationPolicy.fields(), &Atom.to_string/1)

  OpenApiSpex.schema(
    %{
      title: "GymVerificationRequirements",
      description: """
      The versioned requirement policy (`required_fields` can depend on the registration country). SimpleFit's
      generic minimum; no jurisdiction-specific requirement is approved yet.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :policy_version,
        :required_fields,
        :min_evidence,
        :max_evidence,
        :max_bytes,
        :content_types,
        :kinds
      ],
      properties: %{
        policy_version: %Schema{type: :string},
        required_fields: %Schema{type: :array, items: %Schema{type: :string, enum: @fields}},
        min_evidence: %Schema{type: :integer, minimum: 0},
        max_evidence: %Schema{type: :integer, minimum: 1},
        max_bytes: %Schema{type: :integer, minimum: 1},
        content_types: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: VerificationPolicy.content_types()}
        },
        kinds: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: Enum.map(VerificationPolicy.kinds(), &Atom.to_string/1)
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymBusinessVerification do
  @moduledoc "OpenAPI schema: a gym's business verification, for its owner (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.VerificationPolicy

  alias SimpleFitWeb.Schemas.{
    GymVerificationApplication,
    GymVerificationDecision,
    GymVerificationEvidence,
    GymVerificationRequirements
  }

  OpenApiSpex.schema(
    %{
      title: "GymBusinessVerification",
      description: """
      The gym's current application (or, after a rejection or revocation, the latest one) with its documents and
      the latest decision. Only a SimpleFit operator decides; nothing the owner sends approves, and no gym setup,
      SimpleFit plan, payment or Stripe capability counts as verification.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :gym_id,
        :status,
        :application,
        :evidence,
        :latest_decision,
        :missing,
        :can_edit,
        :can_submit,
        :requirements
      ],
      properties: %{
        gym_id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: [
            "not_started",
            "draft",
            "submitted",
            "changes_requested",
            "approved",
            "rejected",
            "revoked"
          ],
          description: """
          `not_started`: no application. `draft`: being prepared. `submitted`: waiting for a SimpleFit operator.
          `changes_requested`: editable again, see `latest_decision.reason_code`; resubmit. `approved`: verified by
          an operator. `rejected` / `revoked`: final for that application; saving details starts a new one.
          """
        },
        application: %Schema{type: :object, allOf: [GymVerificationApplication], nullable: true},
        evidence: %Schema{
          type: :array,
          items: GymVerificationEvidence,
          description: "The application's documents (removed ones omitted), oldest first."
        },
        latest_decision: %Schema{type: :object, allOf: [GymVerificationDecision], nullable: true},
        missing: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: Enum.map(VerificationPolicy.fields(), &Atom.to_string/1) ++ ["evidence"]
          },
          description:
            "What submission still needs (required fields, and `evidence` without enough documents)."
        },
        can_edit: %Schema{type: :boolean, description: "Saving details is allowed now."},
        can_submit: %Schema{
          type: :boolean,
          description: "Submitting is allowed now (complete, no upload pending)."
        },
        requirements: GymVerificationRequirements
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymBusinessVerificationResponse do
  @moduledoc "OpenAPI schema: the `{verification: ...}` envelope (SF-103)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymBusinessVerification

  OpenApiSpex.schema(
    %{
      title: "GymBusinessVerificationResponse",
      type: :object,
      additionalProperties: false,
      required: [:verification],
      properties: %{verification: GymBusinessVerification}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymBusinessVerificationRequest do
  @moduledoc "OpenAPI schema: business details to save in the owner's draft (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @text %Schema{type: :string, nullable: true}

  OpenApiSpex.schema(
    %{
      title: "GymBusinessVerificationRequest",
      description: """
      Any subset of the details; blank or `null` clears one. `revision`: the current application's revision, or
      absent to start an application when there is none (or after a rejection or revocation). Nothing is
      required while drafting.
      """,
      type: :object,
      additionalProperties: false,
      properties: %{
        revision: %Schema{type: :integer, minimum: 1},
        legal_name: %{@text | maxLength: 200},
        registration_country: %{@text | description: "ISO 3166-1 alpha-2 (case-insensitive)."},
        registration_number: %{@text | maxLength: 40},
        address_line: %{@text | maxLength: 200},
        postal_code: %{@text | maxLength: 20},
        city: %{@text | maxLength: 80},
        website: %{@text | maxLength: 200, description: "An http(s) address."}
      },
      example: %{legal_name: "Simple Boxing Sp. z o.o.", registration_country: "PL"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymBusinessVerificationRevisionRequest do
  @moduledoc "OpenAPI schema: the revision a change is made on (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GymBusinessVerificationRevisionRequest",
      type: :object,
      additionalProperties: false,
      required: [:revision],
      properties: %{
        revision: %Schema{
          type: :integer,
          minimum: 1,
          description: "The application revision the owner is looking at."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVerificationEvidenceRequest do
  @moduledoc "OpenAPI schema: a document to upload (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.VerificationPolicy

  OpenApiSpex.schema(
    %{
      title: "GymVerificationEvidenceRequest",
      description:
        "The document's kind, base file name, content type and exact size; the upload must match them.",
      type: :object,
      additionalProperties: false,
      required: [:revision, :kind, :file_name, :content_type, :byte_size],
      properties: %{
        revision: %Schema{type: :integer, minimum: 1},
        kind: %Schema{
          type: :string,
          enum: Enum.map(VerificationPolicy.kinds(), &Atom.to_string/1)
        },
        file_name: %Schema{type: :string, minLength: 1, maxLength: 120},
        content_type: %Schema{type: :string, enum: VerificationPolicy.content_types()},
        byte_size: %Schema{type: :integer, minimum: 1, maximum: VerificationPolicy.max_bytes()}
      },
      example: %{
        revision: 2,
        kind: "registration_extract",
        file_name: "registry-extract.pdf",
        content_type: "application/pdf",
        byte_size: 182_311
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVerificationUpload do
  @moduledoc "OpenAPI schema: a presigned direct upload to private storage (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GymVerificationUpload",
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

defmodule SimpleFitWeb.Schemas.GymVerificationEvidenceResponse do
  @moduledoc "OpenAPI schema: an announced document and its upload (SF-103)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.{
    GymBusinessVerification,
    GymVerificationEvidence,
    GymVerificationUpload
  }

  OpenApiSpex.schema(
    %{
      title: "GymVerificationEvidenceResponse",
      type: :object,
      additionalProperties: false,
      required: [:verification, :evidence, :upload],
      properties: %{
        verification: GymBusinessVerification,
        evidence: GymVerificationEvidence,
        upload: GymVerificationUpload
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymGoLiveCheck do
  @moduledoc "OpenAPI schema: one go-live readiness check (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.GoLive

  OpenApiSpex.schema(
    %{
      title: "GymGoLiveCheck",
      description: "One check, derived on this read from the gym's own records.",
      type: :object,
      additionalProperties: false,
      required: [:key, :status, :requiredness, :reason_code, :action, :source],
      properties: %{
        key: %Schema{
          type: :string,
          enum: Enum.map(GoLive.keys(), &Atom.to_string/1),
          description: "Stable key, in display order."
        },
        status: %Schema{
          type: :string,
          enum: ["passed", "failed", "pending", "blocked", "unavailable"],
          description: """
          `passed` / `failed`: the fact holds or not. `pending`: waiting for someone else (an operator's review).
          `blocked`: needs a decision outside the gym (not approved yet). `unavailable`: the feature does not exist
          yet; show it as coming later.
          """
        },
        requiredness: %Schema{
          type: :string,
          enum: ["required", "recommended", "optional", "future"],
          description:
            "Under the readiness policy; only `required` checks count for `prerequisites_met`."
        },
        reason_code: %Schema{
          type: :string,
          description: """
          Why, as a stable code, e.g. `approved`, `in_review`, `not_started`, `changes_requested`, `rejected`,
          `revoked`, `location_missing`, `no_upcoming_class`, `decisions_not_approved`,
          `public_surface_not_available`.
          """
        },
        action: %Schema{
          type: :string,
          nullable: true,
          enum: [
            "open_verification",
            "open_locations",
            "open_timetable",
            "open_staff",
            "open_members",
            "open_memberships",
            nil
          ],
          description: "Where the owner acts on it, when they can; `null` otherwise."
        },
        source: %Schema{
          type: :string,
          enum: [
            "gym_setup",
            "business_verification",
            "timetable",
            "gym_staff",
            "gym_members",
            "member_products",
            "payments",
            "publication",
            "community"
          ],
          description: "The backend domain the check reads."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymGoLive do
  @moduledoc "OpenAPI schema: a gym's go-live readiness (SF-103)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymGoLiveCheck

  OpenApiSpex.schema(
    %{
      title: "GymGoLive",
      description: """
      Readiness derived from the gym's records on every read; nothing is stored or settable. It never publishes:
      SimpleFit has no approved public gym surface or publishing policy, so `publication.status` is always
      `unavailable`.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :gym_id,
        :policy_version,
        :evaluated_at,
        :prerequisites_met,
        :checks,
        :publication
      ],
      properties: %{
        gym_id: %Schema{type: :string, format: :uuid},
        policy_version: %Schema{type: :string},
        evaluated_at: %Schema{type: :string, format: :"date-time"},
        prerequisites_met: %Schema{
          type: :boolean,
          description: "Every `required` check passed on this read (re-derived each time)."
        },
        checks: %Schema{type: :array, items: GymGoLiveCheck},
        publication: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:status, :reason_code],
          properties: %{
            status: %Schema{type: :string, enum: ["unavailable"]},
            reason_code: %Schema{type: :string, enum: ["public_surface_not_available"]}
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymGoLiveResponse do
  @moduledoc "OpenAPI schema: the `{go_live: ...}` envelope (SF-103)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymGoLive

  OpenApiSpex.schema(
    %{
      title: "GymGoLiveResponse",
      type: :object,
      additionalProperties: false,
      required: [:go_live],
      properties: %{go_live: GymGoLive}
    },
    struct?: false
  )
end
