defmodule SimpleFitWeb.Schemas.CoachInvitationFields do
  @moduledoc """
  Shared OpenAPI definitions of coach invitations (SF-57). Vocabularies come
  from the domain, so the contract cannot drift.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Coaching.Invitations
  alias SimpleFit.Fighters

  @doc "An invitation token: `sfi_` and 43 base64url characters, from the E08 link fragment."
  def token do
    %Schema{
      type: :string,
      description: """
      The one-time invitation token from the E08 link fragment (`#token=…`). Send it only in request bodies,
      never in a URL. Any value that is not a current token answers `410 invitation_unavailable`.
      """,
      example: "sfi_3q2-7wEXAMPLEonlyEXAMPLEonlyEXAMPLEonlyEXAMPLEo"
    }
  end

  @doc "The disclosure a recipient reviews."
  def disclosure do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:fields, :never_shared, :version],
      properties: %{
        version: %Schema{
          type: :string,
          description: "The current disclosure version; accepting must echo exactly this value."
        },
        fields: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: Enum.map(Fighters.coach_visible_fields(), &to_string/1)
          },
          description: "The fighter profile fields the coach would see after acceptance."
        },
        never_shared: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: Enum.map(Invitations.never_shared(), &to_string/1)},
          description: "What is never shared with a coach, as categories for the client to label."
        }
      }
    }
  end
end

defmodule SimpleFitWeb.Schemas.CoachDataRulesResponse do
  @moduledoc "OpenAPI schema: the coach data-rules version and the viewer's acknowledgement."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CoachDataRulesResponse",
      type: :object,
      additionalProperties: false,
      required: [:data_rules],
      properties: %{
        data_rules: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:acknowledged_at, :document, :document_version],
          properties: %{
            document: %Schema{
              type: :object,
              allOf: [SimpleFitWeb.Schemas.LegalDocumentRef],
              nullable: true,
              description: """
              The current data-rules text in the requested `language` (`null` while no version is published).
              Acknowledge with its `version` and `language`; no `language` (no approved variant in the requested
              language): acknowledging is not possible yet.
              """
            },
            document_version: %Schema{
              type: :string,
              nullable: true,
              description:
                "The coach data-rules version to acknowledge before inviting; `null` while none is configured."
            },
            acknowledged_at: %Schema{
              type: :string,
              format: :"date-time",
              nullable: true,
              description: "When the viewer acknowledged that version; `null` until then."
            }
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachDataRulesAcknowledgeRequest do
  @moduledoc "OpenAPI schema: acknowledging a coach data-rules version."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CoachDataRulesAcknowledgeRequest",
      type: :object,
      required: [:document_language, :document_version],
      properties: %{
        document_version: %Schema{
          type: :string,
          minLength: 1,
          maxLength: 64,
          description: "The version from `getMyCoachDataRules` that the coach was shown."
        },
        document_language: %Schema{
          type: :string,
          enum: SimpleFit.Legal.Registry.languages(),
          description:
            "The `document.language` of the text the coach was shown (an approved variant)."
        }
      },
      example: %{document_version: "coach-data-rules-2026-11-1", document_language: "en"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitationCreateRequest do
  @moduledoc "OpenAPI schema: inviting someone by email."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CoachInvitationCreateRequest",
      description: """
      The address to invite and an optional note. Any other field (a coach id, a status, an expiry...) is
      rejected with `422 validation_error`, code `invalid` under that field name.
      """,
      type: :object,
      additionalProperties: false,
      required: [:email],
      properties: %{
        email: %Schema{
          type: :string,
          maxLength: 320,
          description:
            "The recipient's email address. Only someone signed in with this address can respond."
        },
        message: %Schema{
          type: :string,
          nullable: true,
          maxLength: 500,
          description:
            "Optional note shown in the email and the preview: one plain-text paragraph, 1-500 characters."
        }
      },
      example: %{email: "fighter@example.com", message: "Saw you at Saturday sparring."}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitation do
  @moduledoc "OpenAPI schema: one invitation as its coach sees it."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CoachInvitation",
      description: """
      An invitation sent by the viewer. The recipient address is masked; whether it belongs to an account is
      never revealed. `expired` is derived from `expires_at`.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :created_at,
        :expires_at,
        :invitation_id,
        :last_sent_at,
        :message,
        :recipient_email,
        :resends_remaining,
        :responded_at,
        :status
      ],
      properties: %{
        invitation_id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ["pending", "accepted", "declined", "cancelled", "expired"]
        },
        recipient_email: %Schema{
          type: :string,
          description: "The invited address, masked (`f•••@example.com`)."
        },
        message: %Schema{type: :string, nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        expires_at: %Schema{type: :string, format: :"date-time"},
        last_sent_at: %Schema{type: :string, format: :"date-time"},
        resends_remaining: %Schema{type: :integer, minimum: 0, maximum: 3},
        responded_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When it was accepted, declined or cancelled."
        }
      },
      example: %{
        invitation_id: "7d1e7c52-1d0b-4a1e-9e3c-2f4f5b1a9c10",
        status: "pending",
        recipient_email: "f•••@example.com",
        message: nil,
        created_at: "2026-10-15T09:00:00.000000Z",
        expires_at: "2026-10-29T09:00:00.000000Z",
        last_sent_at: "2026-10-15T09:00:00.000000Z",
        resends_remaining: 3,
        responded_at: nil
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitationResponse do
  @moduledoc "OpenAPI schema: one invitation of the viewer."

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "CoachInvitationResponse",
      type: :object,
      additionalProperties: false,
      required: [:invitation],
      properties: %{invitation: SimpleFitWeb.Schemas.CoachInvitation}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitationList do
  @moduledoc "OpenAPI schema: one page of the viewer's invitations."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CoachInvitationList",
      type: :object,
      additionalProperties: false,
      required: [:invitations, :next_cursor],
      properties: %{
        invitations: %Schema{
          type: :array,
          items: SimpleFitWeb.Schemas.CoachInvitation,
          description: "Newest first."
        },
        next_cursor: %Schema{
          type: :string,
          nullable: true,
          description: "Pass as `cursor` to read the next page; `null` on the last page. Opaque."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitationTokenRequest do
  @moduledoc "OpenAPI schema: a request carrying only an invitation token."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.CoachInvitationFields

  OpenApiSpex.schema(
    %{
      title: "CoachInvitationTokenRequest",
      type: :object,
      required: [:token],
      properties: %{token: CoachInvitationFields.token()}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitationPreviewRequest do
  @moduledoc "OpenAPI schema: previewing an invitation link (token and the language to read it in)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.CoachInvitationFields

  OpenApiSpex.schema(
    %{
      title: "CoachInvitationPreviewRequest",
      type: :object,
      required: [:token],
      properties: %{
        token: CoachInvitationFields.token(),
        language: %Schema{
          type: :string,
          description:
            "The language to present the disclosure text in (the app language); see `document`."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitationPreview do
  @moduledoc "OpenAPI schema: what an invitation link shows before responding."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.CoachInvitationFields

  OpenApiSpex.schema(
    %{
      title: "CoachInvitationPreview",
      description: """
      The inviting coach's public identity, their note, the expiry and the disclosure the recipient would
      accept. Nothing about the recipient or any account.
      """,
      type: :object,
      additionalProperties: false,
      required: [:disclosure, :document, :invitation],
      properties: %{
        document: %Schema{
          type: :object,
          allOf: [SimpleFitWeb.Schemas.LegalDocumentRef],
          nullable: true,
          description: """
          The current disclosure's approved text in the requested `language` (metadata only when that language has
          no approved variant: then the fighter cannot accept in it). `null` while no disclosure is published.
          """
        },
        invitation: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:coach, :expires_at, :message],
          properties: %{
            coach: %Schema{
              type: :object,
              additionalProperties: false,
              required: [:brand_name, :display_name],
              properties: %{
                display_name: %Schema{type: :string, nullable: true, example: "Coach Marek"},
                brand_name: %Schema{type: :string, nullable: true, example: "Marek Boxing"}
              }
            },
            message: %Schema{type: :string, nullable: true},
            expires_at: %Schema{type: :string, format: :"date-time"}
          }
        },
        disclosure: CoachInvitationFields.disclosure()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitationAcceptRequest do
  @moduledoc "OpenAPI schema: accepting an invitation and its disclosure."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.CoachInvitationFields

  OpenApiSpex.schema(
    %{
      title: "CoachInvitationAcceptRequest",
      type: :object,
      required: [:disclosure_version, :document_language, :token],
      properties: %{
        token: CoachInvitationFields.token(),
        document_language: %Schema{
          type: :string,
          enum: SimpleFit.Legal.Registry.languages(),
          description:
            "The `document.language` of the disclosure text the fighter was shown (an approved variant)."
        },
        disclosure_version: %Schema{
          type: :string,
          minLength: 1,
          maxLength: 64,
          description:
            "The `disclosure.version` the recipient was shown (`previewCoachInvitation`). Any other value: `409`."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.CoachInvitationAcceptResponse do
  @moduledoc "OpenAPI schema: the result of an acceptance."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CoachInvitationAcceptResponse",
      type: :object,
      additionalProperties: false,
      required: [:outcome, :relationship_id],
      properties: %{
        relationship_id: %Schema{
          type: :string,
          format: :uuid,
          description: "The active relationship (see `listMyCoaches`)."
        },
        outcome: %Schema{
          type: :string,
          enum: ["created", "already_connected"],
          description: """
          `created`: a new relationship under the accepted disclosure. `already_connected`: the pair already had an
          active relationship, which is unchanged (its accepted disclosure is not widened).
          """
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.IncomingCoachInvitation do
  @moduledoc "OpenAPI schema: one invitation as its recipient sees it (SF-73)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "IncomingCoachInvitation",
      description: """
      An invitation addressed to one of the viewer's verified email identities. Shows the inviting coach's
      public identity and note; never the token, the address it was sent to or anything about other accounts.
      Appearing here is not a relationship. `expired` is derived from `expires_at`.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :coach,
        :created_at,
        :expires_at,
        :invitation_id,
        :message,
        :responded_at,
        :status
      ],
      properties: %{
        invitation_id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ["pending", "accepted", "declined", "cancelled", "expired"]
        },
        coach: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:brand_name, :display_name],
          description: "The inviting coach's public identity.",
          properties: %{
            display_name: %Schema{type: :string, nullable: true, example: "Coach Marek"},
            brand_name: %Schema{type: :string, nullable: true, example: "Marek Boxing"}
          }
        },
        message: %Schema{type: :string, nullable: true, description: "The coach's note."},
        created_at: %Schema{type: :string, format: :"date-time"},
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "A resend moves it; past it a pending invitation is `expired`."
        },
        responded_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When it was accepted, declined or cancelled."
        }
      },
      example: %{
        invitation_id: "7d1e7c52-1d0b-4a1e-9e3c-2f4f5b1a9c10",
        status: "pending",
        coach: %{display_name: "Coach Marek", brand_name: "Marek Boxing"},
        message: nil,
        created_at: "2026-10-15T09:00:00.000000Z",
        expires_at: "2026-10-29T09:00:00.000000Z",
        responded_at: nil
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.IncomingCoachInvitationList do
  @moduledoc "OpenAPI schema: one page of the invitations addressed to the viewer (SF-73)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "IncomingCoachInvitationList",
      type: :object,
      additionalProperties: false,
      required: [:invitations, :next_cursor],
      properties: %{
        invitations: %Schema{
          type: :array,
          items: SimpleFitWeb.Schemas.IncomingCoachInvitation,
          description: "Newest first."
        },
        next_cursor: %Schema{
          type: :string,
          nullable: true,
          description: "Pass as `cursor` to read the next page; `null` on the last page. Opaque."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.IncomingCoachInvitationAcceptRequest do
  @moduledoc "OpenAPI schema: accepting an invitation by id and its disclosure (SF-73)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "IncomingCoachInvitationAcceptRequest",
      type: :object,
      required: [:disclosure_version, :document_language],
      properties: %{
        disclosure_version: %Schema{
          type: :string,
          minLength: 1,
          maxLength: 64,
          description:
            "Exactly the `disclosure.version` shown by `previewMyIncomingCoachInvitation`."
        },
        document_language: %Schema{
          type: :string,
          enum: SimpleFit.Legal.Registry.languages(),
          description:
            "The `document.language` of the disclosure text the fighter was shown (an approved variant)."
        }
      }
    },
    struct?: false
  )
end
