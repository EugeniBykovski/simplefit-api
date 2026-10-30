defmodule SimpleFitWeb.Schemas.GymMemberFields do
  @moduledoc """
  Shared OpenAPI definitions of gym members, enrollment and member
  invitations (SF-95). Vocabularies come from the `SimpleFit.Gyms` schemas.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.{Member, MemberImport, MemberInvitation}
  alias SimpleFitWeb.Schemas.GymStaffFields

  @doc "A membership status."
  def status do
    %Schema{
      type: :string,
      enum: Enum.map(Member.statuses(), &Atom.to_string/1),
      description: """
      `requested` (a join-code request waiting for the gym), `active`, `rejected` (by the gym; final),
      `cancelled` (by the requester; final) or `ended` (left or removed; final). Re-enrolling creates a new
      membership.
      """
    }
  end

  @doc "How a membership started."
  def joined_via do
    %Schema{
      type: :string,
      enum: ["join_code", "invitation"],
      description:
        "`join_code` (a request, possibly auto-approved) or `invitation` (an accepted E07)."
    }
  end

  @doc "Why a membership ended."
  def ended_reason do
    %Schema{
      type: :string,
      nullable: true,
      enum: Enum.map(Member.ended_reasons(), &Atom.to_string/1) ++ [nil],
      description:
        "`left` (by the member) or `removed` (by an owner or manager); `null` unless ended."
    }
  end

  @doc "A member invitation's effective status."
  def invitation_status do
    %Schema{
      type: :string,
      enum: Enum.map(MemberInvitation.statuses(), &Atom.to_string/1),
      description: """
      `pending` until answered, cancelled or expired (7 days after it was last sent, server time); `accepted`,
      `declined`, `cancelled` and `expired` are final. A `pending` invitation past its expiry is reported as
      `expired`.
      """
    }
  end

  @doc "A member invitation token from the E07 link fragment."
  def token do
    %Schema{
      type: :string,
      description: """
      The one-time token from the E07 link fragment (`<web app>/invite/gym#token=…`): `sgm_` and 43 base64url
      characters. Send it only in request bodies, never in a URL, a log or app navigation. Any value that is not
      a current token answers `410 invitation_unavailable`.
      """,
      example: "sgm_3q2-7wEXAMPLEonlyEXAMPLEonlyEXAMPLEonlyEXAMPLEo"
    }
  end

  @doc "A join code as typed."
  def join_code do
    %Schema{
      type: :string,
      maxLength: 32,
      description: """
      The gym's join code (8 symbols, shown as `ABCD-EFGH`). Case, spaces and hyphens are ignored; `O`, `I` and
      `L` read as `0`, `1`, `1`.
      """,
      example: "K7QM-3XRD"
    }
  end

  @doc "The gym as a member sees it."
  def gym do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:gym_id, :name],
      properties: %{
        gym_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string, nullable: true}
      }
    }
  end

  @doc "The common membership facts."
  def membership_properties do
    %{
      gym_member_id: %Schema{type: :string, format: :uuid},
      status: status(),
      joined_via: joined_via(),
      auto_approved: %Schema{
        type: :boolean,
        description: "Activated by the gym's auto-approval setting rather than by a staff member."
      },
      requested_at: %{
        GymStaffFields.timestamp(true)
        | description: "When the join request was made (`null` for an invitation)."
      },
      joined_at: %{GymStaffFields.timestamp(true) | description: "When it became active."},
      responded_at: %{
        GymStaffFields.timestamp(true)
        | description: "When a request was rejected or cancelled."
      },
      ended_at: GymStaffFields.timestamp(true),
      ended_reason: ended_reason()
    }
  end

  @doc "The required keys of `membership_properties/0`."
  def membership_required,
    do: [
      :gym_member_id,
      :status,
      :joined_via,
      :auto_approved,
      :requested_at,
      :joined_at,
      :responded_at,
      :ended_at,
      :ended_reason
    ]

  @doc "A row outcome of the member list preview."
  def import_outcome do
    %Schema{
      type: :string,
      enum: Enum.map(MemberImport.outcomes(), &Atom.to_string/1),
      description: """
      `ready` (an invitation could be sent), `missing_email`, `invalid_email`, `duplicate` (the same address on
      an earlier line), `already_member` (an active member of this gym), `request_pending` (a pending join
      request at this gym), `already_invited` (a pending member invitation of this gym).
      """
    }
  end
end

defmodule SimpleFitWeb.Schemas.GymMember do
  @moduledoc "OpenAPI schema: a gym membership as the gym's staff see it (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymMemberFields

  OpenApiSpex.schema(
    %{
      title: "GymMember",
      description: """
      A membership of this gym. Only gym facts and a short name: no email, user id, profile, other gym,
      Coach–Fighter fact or training data (D-G06).
      """,
      type: :object,
      additionalProperties: false,
      required: [:name | GymMemberFields.membership_required()],
      properties:
        Map.put(GymMemberFields.membership_properties(), :name, %Schema{
          type: :string,
          nullable: true,
          description:
            "First name and the initial of the last name (\"Marta K.\"), from the account name; `null` without one."
        }),
      example: %{
        gym_member_id: "5d1c1a3e-2b1d-4a8e-9a54-0d6b2f0c1e70",
        status: "active",
        name: "Marta K.",
        joined_via: "join_code",
        auto_approved: false,
        requested_at: "2026-10-30T09:00:00Z",
        joined_at: "2026-10-30T10:00:00Z",
        responded_at: nil,
        ended_at: nil,
        ended_reason: nil
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberList do
  @moduledoc "OpenAPI schema: one page of a gym's members or join requests (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymMember}

  OpenApiSpex.schema(
    %{
      title: "GymMemberList",
      type: :object,
      additionalProperties: false,
      required: [:members, :next_cursor],
      properties: %{
        members: %Schema{type: :array, items: GymMember, description: "Oldest first."},
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberResponse do
  @moduledoc "OpenAPI schema: one gym membership as the gym sees it."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymMember

  OpenApiSpex.schema(
    %{
      title: "GymMemberResponse",
      type: :object,
      additionalProperties: false,
      required: [:member],
      properties: %{member: GymMember}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymMembership do
  @moduledoc "OpenAPI schema: one of the viewer's own gym memberships (SF-95)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymMemberFields

  OpenApiSpex.schema(
    %{
      title: "MyGymMembership",
      description: """
      The viewer's membership of a gym, as a participant. It grants no gym workspace or staff permission and is
      unrelated to any Fighter or Coach profile.
      """,
      type: :object,
      additionalProperties: false,
      required: [:gym | GymMemberFields.membership_required()],
      properties: Map.put(GymMemberFields.membership_properties(), :gym, GymMemberFields.gym())
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymMembershipList do
  @moduledoc "OpenAPI schema: one page of the viewer's gym memberships (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, MyGymMembership}

  OpenApiSpex.schema(
    %{
      title: "MyGymMembershipList",
      type: :object,
      additionalProperties: false,
      required: [:memberships, :next_cursor],
      properties: %{
        memberships: %Schema{type: :array, items: MyGymMembership, description: "Newest first."},
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymMembershipResponse do
  @moduledoc "OpenAPI schema: one of the viewer's gym memberships."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.MyGymMembership

  OpenApiSpex.schema(
    %{
      title: "MyGymMembershipResponse",
      type: :object,
      additionalProperties: false,
      required: [:membership],
      properties: %{membership: MyGymMembership}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymJoinRequest do
  @moduledoc "OpenAPI schema: a join code in a request body (SF-95)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymMemberFields

  OpenApiSpex.schema(
    %{
      title: "GymJoinRequest",
      type: :object,
      required: [:code],
      properties: %{code: GymMemberFields.join_code()}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymJoinPreviewResponse do
  @moduledoc "OpenAPI schema: what a join code shows before joining (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GymJoinPreviewResponse",
      type: :object,
      additionalProperties: false,
      required: [:preview],
      properties: %{
        preview: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:gym, :requires_approval],
          properties: %{
            gym: %Schema{
              type: :object,
              additionalProperties: false,
              required: [:name],
              properties: %{name: %Schema{type: :string}}
            },
            requires_approval: %Schema{
              type: :boolean,
              description:
                "Whether joining sends a request the gym approves (`false` only with the gym's explicit auto-approval)."
            }
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymEnrollmentSettings do
  @moduledoc "OpenAPI schema: a gym's enrollment settings (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "GymEnrollmentSettings",
      type: :object,
      additionalProperties: false,
      required: [
        :join_code,
        :join_code_rotated_at,
        :auto_approve,
        :auto_approve_changed_at,
        :can_manage
      ],
      properties: %{
        join_code: %Schema{
          type: :string,
          nullable: true,
          description: "The current code (`ABCD-EFGH`); `null` when joining by code is off.",
          example: "K7QM-3XRD"
        },
        join_code_rotated_at: GymStaffFields.timestamp(true),
        auto_approve: %Schema{
          type: :boolean,
          description: """
          Whether a join-code request starts active (default `false`). Even when on, a joiner without a completed
          account and a verified sign-in identity gets a request.
          """
        },
        auto_approve_changed_at: GymStaffFields.timestamp(true),
        can_manage: %Schema{
          type: :boolean,
          description:
            "Whether the viewer may rotate or disable the code and switch auto-approval."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymEnrollmentSettingsResponse do
  @moduledoc "OpenAPI schema: a gym's enrollment settings."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymEnrollmentSettings

  OpenApiSpex.schema(
    %{
      title: "GymEnrollmentSettingsResponse",
      type: :object,
      additionalProperties: false,
      required: [:enrollment],
      properties: %{enrollment: GymEnrollmentSettings}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymEnrollmentSettingsUpdateRequest do
  @moduledoc "OpenAPI schema: change a gym's auto-approval (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GymEnrollmentSettingsUpdateRequest",
      description: "Exactly `auto_approve`; any other field is a `422 validation_error`.",
      type: :object,
      required: [:auto_approve],
      properties: %{auto_approve: %Schema{type: :boolean}},
      example: %{auto_approve: false}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberInvitation do
  @moduledoc "OpenAPI schema: a member invitation as its gym sees it (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymMemberFields, GymStaffFields}

  OpenApiSpex.schema(
    %{
      title: "GymMemberInvitation",
      description: """
      A member invitation issued by this gym. The address is masked; the token and any account of the recipient
      are never shown. It grants nothing until its recipient accepts it.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :invitation_id,
        :status,
        :recipient_email,
        :invited_by,
        :created_at,
        :expires_at,
        :last_sent_at,
        :resends_remaining,
        :responded_at,
        :gym_member_id
      ],
      properties: %{
        invitation_id: %Schema{type: :string, format: :uuid},
        status: GymMemberFields.invitation_status(),
        recipient_email: %Schema{
          type: :string,
          description: "The invited address, masked (`m•••@example.com`)."
        },
        invited_by: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:staff_membership_id, :name],
          properties: %{
            staff_membership_id: %Schema{type: :string, format: :uuid},
            name: %Schema{type: :string, nullable: true}
          }
        },
        created_at: GymStaffFields.timestamp(),
        expires_at: GymStaffFields.timestamp(),
        last_sent_at: GymStaffFields.timestamp(),
        resends_remaining: %Schema{type: :integer, minimum: 0, maximum: 3},
        responded_at: GymStaffFields.timestamp(true),
        gym_member_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The membership an acceptance activated."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberInvitationList do
  @moduledoc "OpenAPI schema: one page of a gym's member invitations (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymMemberInvitation}

  OpenApiSpex.schema(
    %{
      title: "GymMemberInvitationList",
      type: :object,
      additionalProperties: false,
      required: [:invitations, :next_cursor],
      properties: %{
        invitations: %Schema{
          type: :array,
          items: GymMemberInvitation,
          description: "Newest first."
        },
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberInvitationResponse do
  @moduledoc "OpenAPI schema: one member invitation as its gym sees it."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymMemberInvitation

  OpenApiSpex.schema(
    %{
      title: "GymMemberInvitationResponse",
      type: :object,
      additionalProperties: false,
      required: [:invitation],
      properties: %{invitation: GymMemberInvitation}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberInvitationCreateRequest do
  @moduledoc "OpenAPI schema: invite an email address to become a member (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GymMemberInvitationCreateRequest",
      description:
        "Exactly `email`; any other field (a name, a plan, a gym id) is a `422 validation_error`.",
      type: :object,
      required: [:email],
      properties: %{
        email: %Schema{
          type: :string,
          description: "The address to invite; normalized like a sign-in address."
        }
      },
      example: %{email: "marta@example.com"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymInvitation do
  @moduledoc "OpenAPI schema: a member invitation as its recipient sees it (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymMemberFields, GymStaffFields}

  OpenApiSpex.schema(
    %{
      title: "MyGymInvitation",
      description: """
      A member invitation sent to one of the viewer's verified email addresses. Reading it changes nothing; only
      an explicit acceptance activates a gym membership.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :invitation_id,
        :status,
        :gym,
        :invited_by,
        :sent_to,
        :created_at,
        :expires_at,
        :responded_at,
        :gym_member_id
      ],
      properties: %{
        invitation_id: %Schema{type: :string, format: :uuid},
        status: GymMemberFields.invitation_status(),
        gym: GymMemberFields.gym(),
        invited_by: GymStaffFields.inviter(),
        sent_to: %Schema{
          type: :string,
          description: "The viewer's own verified address the invitation was sent to."
        },
        created_at: GymStaffFields.timestamp(),
        expires_at: GymStaffFields.timestamp(),
        responded_at: GymStaffFields.timestamp(true),
        gym_member_id: %Schema{type: :string, format: :uuid, nullable: true}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymInvitationList do
  @moduledoc "OpenAPI schema: one page of the member invitations sent to the viewer (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, MyGymInvitation}

  OpenApiSpex.schema(
    %{
      title: "MyGymInvitationList",
      type: :object,
      additionalProperties: false,
      required: [:invitations, :next_cursor],
      properties: %{
        invitations: %Schema{type: :array, items: MyGymInvitation, description: "Newest first."},
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymInvitationResponse do
  @moduledoc "OpenAPI schema: one member invitation sent to the viewer."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.MyGymInvitation

  OpenApiSpex.schema(
    %{
      title: "MyGymInvitationResponse",
      type: :object,
      additionalProperties: false,
      required: [:invitation],
      properties: %{invitation: MyGymInvitation}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymInvitationTokenRequest do
  @moduledoc "OpenAPI schema: a member invitation token in a request body (SF-95)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymMemberFields

  OpenApiSpex.schema(
    %{
      title: "GymInvitationTokenRequest",
      type: :object,
      required: [:token],
      properties: %{token: GymMemberFields.token()}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymInvitationPreviewResponse do
  @moduledoc "OpenAPI schema: what an E07 link shows before sign-in (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "GymInvitationPreviewResponse",
      type: :object,
      additionalProperties: false,
      required: [:preview],
      properties: %{
        preview: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:gym, :invited_by, :expires_at],
          properties: %{
            gym: %Schema{
              type: :object,
              additionalProperties: false,
              required: [:name],
              properties: %{name: %Schema{type: :string, nullable: true}}
            },
            invited_by: GymStaffFields.inviter(),
            expires_at: GymStaffFields.timestamp()
          }
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymInvitationAcceptResponse do
  @moduledoc "OpenAPI schema: the result of accepting a member invitation (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.MyGymInvitation

  OpenApiSpex.schema(
    %{
      title: "GymInvitationAcceptResponse",
      type: :object,
      additionalProperties: false,
      required: [:invitation, :gym_id, :gym_member_id, :outcome],
      properties: %{
        invitation: MyGymInvitation,
        gym_id: %Schema{type: :string, format: :uuid},
        gym_member_id: %Schema{type: :string, format: :uuid},
        outcome: %Schema{
          type: :string,
          enum: ["accepted", "already_accepted"],
          description:
            "`already_accepted` when the viewer had accepted it before (a repeated request)."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberImportPreviewRequest do
  @moduledoc "OpenAPI schema: a member list to preview (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "GymMemberImportPreviewRequest",
      description:
        "Exactly `csv` and an optional `mapping`; any other field is a `422 validation_error`.",
      type: :object,
      required: [:csv],
      properties: %{
        csv: %Schema{
          type: :string,
          description: """
          The CSV text: UTF-8, header row first, `,`, `;` or tab separated, at most 1 MB, 1,000 data rows, 30
          columns and 500 bytes per field. Never stored or logged.
          """
        },
        mapping: %Schema{
          type: :object,
          additionalProperties: false,
          description: """
          Which header column holds each SimpleFit field. Without it, columns are suggested from common headers.
          `email` must end up mapped.
          """,
          properties: %{
            email: %Schema{type: :string, nullable: true},
            name: %Schema{type: :string, nullable: true}
          }
        }
      },
      example: %{csv: "name;email\nMarta Kowalska;marta@example.com\n"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberImportPreviewResponse do
  @moduledoc "OpenAPI schema: the dry-run preview of a member list (SF-95)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymMemberFields

  @counts [
    :total,
    :ready,
    :missing_email,
    :invalid_email,
    :duplicate,
    :already_member,
    :request_pending,
    :already_invited
  ]

  OpenApiSpex.schema(
    %{
      title: "GymMemberImportPreviewResponse",
      type: :object,
      additionalProperties: false,
      required: [:preview],
      properties: %{
        preview: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:persisted, :commit, :delimiter, :columns, :summary, :rows],
          properties: %{
            persisted: %Schema{
              type: :boolean,
              enum: [false],
              description: "Always `false`: a dry run stores nothing."
            },
            commit: %Schema{
              type: :object,
              additionalProperties: false,
              required: [:available, :blocked_by],
              description: """
              Whether the list can be committed. Not yet: storing third parties' contacts and inviting them in bulk
              wait for an approved legal basis and retention rule (`blocked_by: legal_basis_pending`).
              """,
              properties: %{
                available: %Schema{type: :boolean, enum: [false]},
                blocked_by: %Schema{type: :string, enum: ["legal_basis_pending"]}
              }
            },
            delimiter: %Schema{type: :string, enum: [",", ";", "\t"]},
            columns: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                additionalProperties: false,
                required: [:header, :field, :status],
                properties: %{
                  header: %Schema{type: :string},
                  field: %Schema{type: :string, nullable: true, enum: ["email", "name", nil]},
                  status: %Schema{
                    type: :string,
                    enum: ["mapped", "not_imported"],
                    description:
                      "Every unmapped column (plan, phone, dates...) is `not_imported`."
                  }
                }
              }
            },
            summary: %Schema{
              type: :object,
              additionalProperties: false,
              required: @counts,
              properties: Map.new(@counts, &{&1, %Schema{type: :integer, minimum: 0}})
            },
            rows: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                additionalProperties: false,
                required: [:line, :email, :name_present, :outcome, :duplicate_of_line],
                properties: %{
                  line: %Schema{
                    type: :integer,
                    minimum: 1,
                    description: "The line where the row starts."
                  },
                  email: %Schema{
                    type: :string,
                    nullable: true,
                    description: "The canonical address, masked; `null` when missing or invalid."
                  },
                  name_present: %Schema{type: :boolean},
                  outcome: GymMemberFields.import_outcome(),
                  duplicate_of_line: %Schema{type: :integer, nullable: true}
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
