defmodule SimpleFitWeb.Schemas.SponsorPartnershipFields do
  @moduledoc false
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.{ApplicationPolicy, Proposal}

  @doc false
  # The market and interest answers, shared by preferences, proposals and the
  # application's submitted answers (SF-113's vocabularies).
  def markets do
    %{
      interests: %Schema{
        type: :array,
        maxItems: length(ApplicationPolicy.interests()),
        items: %Schema{type: :string, enum: ApplicationPolicy.interests()}
      },
      market_scope: %Schema{type: :string, enum: ApplicationPolicy.scopes(), nullable: true},
      market_countries: %Schema{
        type: :array,
        maxItems: 50,
        items: %Schema{type: :string, pattern: "^[A-Za-z]{2}$"},
        description: "ISO 3166-1 alpha-2; none when the scope is `global`."
      },
      market_cities: %Schema{
        type: :array,
        maxItems: 20,
        items: %Schema{type: :string, minLength: 1, maxLength: 80},
        description: "Only with the `cities` scope."
      }
    }
  end

  @doc false
  def proposal_answers do
    Map.merge(markets(), %{
      title: %Schema{type: :string, minLength: 1, maxLength: 120, nullable: true},
      summary: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 4000,
        nullable: true,
        description: "Plain text: what the organization would like to explore with SimpleFit."
      }
    })
  end

  @doc false
  def statuses, do: Enum.map(Proposal.statuses(), &Atom.to_string/1)

  @doc false
  def nullable_time, do: %Schema{type: :string, format: :"date-time", nullable: true}

  @doc false
  # The body of an accept or decline (a confirmed decision): its reason codes.
  def decision(title, reasons, description) do
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
          description: "The proposal's revision. Required to execute."
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

defmodule SimpleFitWeb.Schemas.SponsorPartnershipPolicyResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.PartnershipPolicy
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipPolicyResponse",
      type: :object,
      additionalProperties: false,
      required: [:policy],
      properties: %{
        policy: %Schema{
          type: :object,
          additionalProperties: false,
          required: [
            :version,
            :interests,
            :scopes,
            :preference_fields,
            :proposal_fields,
            :required,
            :open_limit,
            :statuses
          ],
          properties: %{
            version: %Schema{type: :string},
            interests: %Schema{type: :array, items: %Schema{type: :string}},
            scopes: %Schema{type: :array, items: %Schema{type: :string}},
            preference_fields: %Schema{
              type: :array,
              items: %Schema{
                type: :string,
                enum: Enum.map(PartnershipPolicy.preference_fields(), &Atom.to_string/1)
              }
            },
            proposal_fields: %Schema{
              type: :array,
              items: %Schema{
                type: :string,
                enum: Enum.map(PartnershipPolicy.proposal_fields(), &Atom.to_string/1)
              }
            },
            required: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Answers a submission needs, plus the market answers its scope needs."
            },
            open_limit: %Schema{
              type: :integer,
              minimum: 1,
              description: "Open proposals an organization may have at once."
            },
            statuses: %Schema{
              type: :array,
              items: %Schema{type: :string, enum: SponsorPartnershipFields.statuses()}
            }
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipOpportunitiesResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipOpportunitiesResponse",
      description: """
      Partnership opportunities for the organization. No opportunity inventory exists and none is invented
      (D-SA21): `availability` is `unavailable` with reason `no_inventory`. A sponsor can still send a general
      partnership inquiry (a proposal), which names no opportunity.
      """,
      type: :object,
      additionalProperties: false,
      required: [:sponsor_id, :availability, :reason],
      properties: %{
        sponsor_id: %Schema{type: :string, format: :uuid},
        availability: %Schema{type: :string, enum: ["unavailable"]},
        reason: %Schema{type: :string, enum: ["no_inventory"]}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipPreferences do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipPreferences",
      description:
        "The organization's current partnership preferences. No budget (D-SA39); nothing commercial.",
      type: :object,
      additionalProperties: false,
      required: [
        :revision,
        :interests,
        :market_scope,
        :market_countries,
        :market_cities,
        :goals,
        :updated_at
      ],
      properties:
        Map.merge(SponsorPartnershipFields.markets(), %{
          revision: %Schema{type: :integer, minimum: 1},
          goals: %Schema{type: :string, minLength: 1, maxLength: 2000, nullable: true},
          updated_at: %Schema{type: :string, format: :"date-time"}
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorApplicationPartnershipAnswers do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "SponsorApplicationPartnershipAnswers",
      description: """
      What the organization's sponsor application last submitted about its interests, markets and goals: read
      from the immutable submission and never changed by preferences. No budget or contact.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :submitted_at,
        :policy_version,
        :interests,
        :market_scope,
        :market_countries,
        :market_cities,
        :goals
      ],
      properties:
        Map.merge(SponsorPartnershipFields.markets(), %{
          submitted_at: %Schema{type: :string, format: :"date-time"},
          policy_version: %Schema{type: :string},
          goals: %Schema{type: :string, nullable: true}
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipPreferencesResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipPreferencesResponse",
      type: :object,
      additionalProperties: false,
      required: [:sponsor_id, :preferences, :application_answers, :can_edit],
      properties: %{
        sponsor_id: %Schema{type: :string, format: :uuid},
        preferences: %Schema{
          allOf: [SimpleFitWeb.Schemas.SponsorPartnershipPreferences],
          type: :object,
          nullable: true,
          description: "`null` until first saved (save with `expected_revision: 0`)."
        },
        application_answers: %Schema{
          allOf: [SimpleFitWeb.Schemas.SponsorApplicationPartnershipAnswers],
          type: :object,
          nullable: true,
          description: "`null` for an organization not made from an application."
        },
        can_edit: %Schema{
          type: :boolean,
          description:
            "Display only: the owner or a manager of an active organization. Every save checks again."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.UpdateSponsorPartnershipPreferencesRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "UpdateSponsorPartnershipPreferencesRequest",
      description: "Only the sent fields change. `null` clears `market_scope` or `goals`.",
      type: :object,
      additionalProperties: false,
      required: [:expected_revision],
      properties:
        Map.merge(SponsorPartnershipFields.markets(), %{
          expected_revision: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "`0` when the organization has no preferences yet; otherwise the current revision."
          },
          goals: %Schema{type: :string, minLength: 1, maxLength: 2000, nullable: true}
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipProposalAnswers do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipProposalAnswers",
      type: :object,
      additionalProperties: false,
      required: [:title, :interests, :market_scope, :market_countries, :market_cities, :summary],
      properties: SponsorPartnershipFields.proposal_answers()
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipProposalSummary do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.ApplicationPolicy
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipProposalSummary",
      type: :object,
      additionalProperties: false,
      required: [
        :proposal_id,
        :kind,
        :status,
        :revision,
        :title,
        :interests,
        :change_request_open,
        :created_at,
        :updated_at,
        :submitted_at,
        :decided_at,
        :withdrawn_at
      ],
      properties: %{
        proposal_id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: ["general_inquiry"]},
        status: %Schema{type: :string, enum: SponsorPartnershipFields.statuses()},
        revision: %Schema{type: :integer, minimum: 1},
        title: %Schema{type: :string, nullable: true},
        interests: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ApplicationPolicy.interests()}
        },
        change_request_open: %Schema{type: :boolean},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"},
        submitted_at: SponsorPartnershipFields.nullable_time(),
        decided_at: SponsorPartnershipFields.nullable_time(),
        withdrawn_at: SponsorPartnershipFields.nullable_time()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipProposalListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipProposalListResponse",
      type: :object,
      additionalProperties: false,
      required: [:sponsor_id, :proposals, :next_cursor, :can_create],
      properties: %{
        sponsor_id: %Schema{type: :string, format: :uuid},
        proposals: %Schema{
          type: :array,
          items: SimpleFitWeb.Schemas.SponsorPartnershipProposalSummary
        },
        next_cursor: %Schema{type: :string, nullable: true},
        can_create: %Schema{
          type: :boolean,
          description:
            "Display only: the viewer may manage partnerships, the organization is active and below its open proposal limit."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipProposal do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.PartnershipPolicy
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  @fields Enum.map(PartnershipPolicy.proposal_fields(), &Atom.to_string/1)

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipProposal",
      description: """
      A nonbinding partnership inquiry to SimpleFit (`binding` is always `false`). No status creates a payment,
      campaign, placement, advertising entitlement, exposure guarantee or access to athlete or gym data;
      `accepted` means only that SimpleFit will follow up. Statuses come from the backend: clients must show an
      unknown status as such, never infer one.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :proposal_id,
        :sponsor_id,
        :kind,
        :status,
        :revision,
        :binding,
        :answers,
        :missing_fields,
        :allowed_actions,
        :change_request,
        :submissions,
        :history,
        :created_by,
        :created_at,
        :updated_at,
        :submitted_at,
        :decided_at,
        :withdrawn_at
      ],
      properties: %{
        proposal_id: %Schema{type: :string, format: :uuid},
        sponsor_id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: ["general_inquiry"]},
        status: %Schema{type: :string, enum: SponsorPartnershipFields.statuses()},
        revision: %Schema{type: :integer, minimum: 1},
        binding: %Schema{type: :boolean, enum: [false]},
        answers: SimpleFitWeb.Schemas.SponsorPartnershipProposalAnswers,
        missing_fields: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: @fields},
          description: "What a submission still needs."
        },
        allowed_actions: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:edit, :submit, :withdraw],
          description: "Display only, for this viewer now. Every request checks again.",
          properties: %{
            edit: %Schema{type: :boolean},
            submit: %Schema{type: :boolean},
            withdraw: %Schema{type: :boolean}
          }
        },
        change_request: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: false,
          required: [:fields, :message, :requested_at],
          description:
            "While `changes_requested`: the answers that may change and SimpleFit's message.",
          properties: %{
            fields: %Schema{type: :array, items: %Schema{type: :string, enum: @fields}},
            message: %Schema{type: :string},
            requested_at: %Schema{type: :string, format: :"date-time"}
          }
        },
        submissions: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:submission_id, :sequence, :submitted_at],
            properties: %{
              submission_id: %Schema{type: :string, format: :uuid},
              sequence: %Schema{type: :integer, minimum: 1},
              submitted_at: %Schema{type: :string, format: :"date-time"}
            }
          }
        },
        history: %Schema{
          type: :array,
          description: "Status changes, oldest first. Who at SimpleFit made them is not shown.",
          items: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:from_status, :to_status, :occurred_at, :actor],
            properties: %{
              from_status: %Schema{
                type: :string,
                enum: SponsorPartnershipFields.statuses(),
                nullable: true
              },
              to_status: %Schema{type: :string, enum: SponsorPartnershipFields.statuses()},
              occurred_at: %Schema{type: :string, format: :"date-time"},
              actor: %Schema{type: :string, enum: ["sponsor_member", "simplefit"]}
            }
          }
        },
        created_by: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:short_name, :is_viewer],
          properties: %{
            short_name: %Schema{type: :string, nullable: true},
            is_viewer: %Schema{type: :boolean}
          }
        },
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"},
        submitted_at: SponsorPartnershipFields.nullable_time(),
        decided_at: SponsorPartnershipFields.nullable_time(),
        withdrawn_at: SponsorPartnershipFields.nullable_time()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipProposalResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipProposalResponse",
      type: :object,
      additionalProperties: false,
      required: [:proposal],
      properties: %{proposal: SimpleFitWeb.Schemas.SponsorPartnershipProposal}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CreateSponsorPartnershipProposalRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "CreateSponsorPartnershipProposalRequest",
      description:
        "A new draft. A repeat with the same `client_request_id` and answers returns the same draft.",
      type: :object,
      additionalProperties: false,
      required: [:client_request_id],
      properties:
        Map.put(
          SponsorPartnershipFields.proposal_answers(),
          :client_request_id,
          %Schema{type: :string, format: :uuid}
        )
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.UpdateSponsorPartnershipProposalRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "UpdateSponsorPartnershipProposalRequest",
      description: "Only the sent answers change. `null` clears an answer.",
      type: :object,
      additionalProperties: false,
      required: [:expected_revision],
      properties:
        Map.put(
          SponsorPartnershipFields.proposal_answers(),
          :expected_revision,
          %Schema{type: :integer, minimum: 1}
        )
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorPartnershipProposalCommandRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorPartnershipProposalCommandRequest",
      description:
        "Submit or withdraw: the proposal's revision and an idempotency key (a repeat of the same request answers the same and changes nothing).",
      type: :object,
      additionalProperties: false,
      required: [:expected_revision, :client_request_id],
      properties: %{
        expected_revision: %Schema{type: :integer, minimum: 1},
        client_request_id: %Schema{type: :string, format: :uuid}
      }
    },
    struct?: false
  )
end

## Operator review

defmodule SimpleFitWeb.Schemas.SponsorProposalOrganization do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorProposalOrganization",
      description: "The proposing organization: never its contacts or members.",
      type: :object,
      additionalProperties: false,
      required: [:sponsor_id, :display_name, :status],
      properties: %{
        sponsor_id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["active", "suspended", "closed"]}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorProposalQueueItem do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.ApplicationPolicy
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    %{
      title: "SponsorProposalQueueItem",
      type: :object,
      additionalProperties: false,
      required: [
        :proposal_id,
        :status,
        :revision,
        :title,
        :interests,
        :organization,
        :submitted_at,
        :submissions,
        :change_request_open
      ],
      properties: %{
        proposal_id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: SponsorPartnershipFields.statuses()},
        revision: %Schema{type: :integer, minimum: 1},
        title: %Schema{type: :string, nullable: true},
        interests: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ApplicationPolicy.interests()}
        },
        organization: SimpleFitWeb.Schemas.SponsorProposalOrganization,
        submitted_at: %Schema{type: :string, format: :"date-time"},
        submissions: %Schema{type: :integer, minimum: 1},
        change_request_open: %Schema{type: :boolean}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorProposalQueueResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorProposalQueueResponse",
      type: :object,
      additionalProperties: false,
      required: [:proposals, :next_cursor],
      properties: %{
        proposals: %Schema{type: :array, items: SimpleFitWeb.Schemas.SponsorProposalQueueItem},
        next_cursor: %Schema{type: :string, nullable: true}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorProposalReview do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.PartnershipPolicy
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  @fields Enum.map(PartnershipPolicy.proposal_fields(), &Atom.to_string/1)

  OpenApiSpex.schema(
    %{
      title: "SponsorProposalReview",
      description:
        "A submitted partnership proposal as an operator reviews it: exactly what was last submitted. Nonbinding.",
      type: :object,
      additionalProperties: false,
      required: [
        :proposal_id,
        :kind,
        :status,
        :revision,
        :organization,
        :latest_submission,
        :submissions,
        :change_request,
        :history,
        :viewer_is_party,
        :submitted_at,
        :decided_at,
        :withdrawn_at
      ],
      properties: %{
        proposal_id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: ["general_inquiry"]},
        status: %Schema{type: :string, enum: SponsorPartnershipFields.statuses()},
        revision: %Schema{type: :integer, minimum: 1},
        organization: SimpleFitWeb.Schemas.SponsorProposalOrganization,
        latest_submission: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: false,
          required: [:submission_id, :sequence, :submitted_at, :policy_version, :answers],
          properties: %{
            submission_id: %Schema{type: :string, format: :uuid},
            sequence: %Schema{type: :integer, minimum: 1},
            submitted_at: %Schema{type: :string, format: :"date-time"},
            policy_version: %Schema{type: :string},
            answers: SimpleFitWeb.Schemas.SponsorPartnershipProposalAnswers
          }
        },
        submissions: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:submission_id, :sequence, :submitted_at],
            properties: %{
              submission_id: %Schema{type: :string, format: :uuid},
              sequence: %Schema{type: :integer, minimum: 1},
              submitted_at: %Schema{type: :string, format: :"date-time"}
            }
          }
        },
        change_request: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: false,
          required: [:reason_code, :fields, :message, :requested_at],
          properties: %{
            reason_code: %Schema{type: :string},
            fields: %Schema{type: :array, items: %Schema{type: :string, enum: @fields}},
            message: %Schema{type: :string},
            requested_at: %Schema{type: :string, format: :"date-time"}
          }
        },
        history: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:from_status, :to_status, :occurred_at, :actor_kind, :reason_code],
            properties: %{
              from_status: %Schema{
                type: :string,
                enum: SponsorPartnershipFields.statuses(),
                nullable: true
              },
              to_status: %Schema{type: :string, enum: SponsorPartnershipFields.statuses()},
              occurred_at: %Schema{type: :string, format: :"date-time"},
              actor_kind: %Schema{type: :string, enum: ["sponsor_member", "operator"]},
              reason_code: %Schema{type: :string, nullable: true}
            }
          }
        },
        viewer_is_party: %Schema{
          type: :boolean,
          description:
            "The reader belongs to the proposing organization (or created it) and can't act on it."
        },
        submitted_at: %Schema{type: :string, format: :"date-time"},
        decided_at: SponsorPartnershipFields.nullable_time(),
        withdrawn_at: SponsorPartnershipFields.nullable_time()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorProposalReviewResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "SponsorProposalReviewResponse",
      type: :object,
      additionalProperties: false,
      required: [:proposal],
      properties: %{proposal: SimpleFitWeb.Schemas.SponsorProposalReview}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.ClaimSponsorProposalRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.ProposalReview

  OpenApiSpex.schema(
    %{
      title: "ClaimSponsorProposalRequest",
      type: :object,
      additionalProperties: false,
      required: [:reason_code],
      properties: %{
        reason_code: %Schema{type: :string, enum: ProposalReview.reasons(:claim)},
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

defmodule SimpleFitWeb.Schemas.RequestSponsorProposalChangesRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.{PartnershipPolicy, ProposalReview}

  OpenApiSpex.schema(
    %{
      title: "RequestSponsorProposalChangesRequest",
      type: :object,
      additionalProperties: false,
      required: [:reason_code, :fields, :message],
      properties: %{
        reason_code: %Schema{type: :string, enum: ProposalReview.reasons(:request_changes)},
        fields: %Schema{
          type: :array,
          minItems: 1,
          items: %Schema{
            type: :string,
            enum: Enum.map(PartnershipPolicy.proposal_fields(), &Atom.to_string/1)
          },
          description: "The answers the organization may change."
        },
        message: %Schema{
          type: :string,
          minLength: 1,
          maxLength: 2000,
          description: "Plain text shown to the organization's members. No email is sent."
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

defmodule SimpleFitWeb.Schemas.AcceptSponsorProposalRequest do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFit.Sponsors.ProposalReview
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    SponsorPartnershipFields.decision(
      "AcceptSponsorProposalRequest",
      ProposalReview.reasons(:accept),
      "Accept a partnership proposal under review (SF-130): SimpleFit will follow up. Creates nothing."
    ),
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.DeclineSponsorProposalRequest do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFit.Sponsors.ProposalReview
  alias SimpleFitWeb.Schemas.SponsorPartnershipFields

  OpenApiSpex.schema(
    SponsorPartnershipFields.decision(
      "DeclineSponsorProposalRequest",
      ProposalReview.reasons(:decline),
      "Decline a partnership proposal under review (SF-130). The reason is internal: never shown to the organization."
    ),
    struct?: false
  )
end
