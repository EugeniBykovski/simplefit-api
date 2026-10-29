defmodule SimpleFitWeb.Schemas.GymStaffFields do
  @moduledoc """
  Shared OpenAPI definitions of gym staff and staff invitations (SF-93).
  Vocabularies come from the `SimpleFit.Gyms` schemas, so the contract cannot
  drift from what the backend accepts.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Gyms.{StaffInvitation, StaffMembership}

  @doc "Every staff role."
  def role do
    %Schema{
      type: :string,
      enum: Enum.map(StaffMembership.roles(), &Atom.to_string/1),
      description: "The fixed gym roles (D-G03): `owner`, `manager`, `coach`, `front_desk`."
    }
  end

  @doc "The roles an invitation or a role change can give (never `owner`)."
  def assignable_role do
    %Schema{
      type: :string,
      enum: Enum.map(StaffInvitation.roles(), &Atom.to_string/1),
      description: """
      `manager`, `coach` or `front_desk`. Never `owner`: ownership moves only by a transfer (D-G04). The owner
      gives any of the three; a manager only `coach` or `front_desk`.
      """
    }
  end

  @doc "An invitation's effective status."
  def invitation_status do
    %Schema{
      type: :string,
      enum: Enum.map(StaffInvitation.statuses(), &Atom.to_string/1),
      description: """
      `pending` until answered, cancelled or expired (7 days after it was last sent, server time); `accepted`,
      `declined`, `cancelled` and `expired` are final. A `pending` invitation past its expiry is reported as
      `expired`.
      """
    }
  end

  @doc "A staff invitation token: `sfs_` and 43 base64url characters, from the E06 link fragment."
  def token do
    %Schema{
      type: :string,
      description: """
      The one-time token from the E06 link fragment (`<web app>/invite/staff#token=…`). Send it only in request
      bodies, never in a URL, a log or app navigation. Any value that is not a current token answers `410
      invitation_unavailable`.
      """,
      example: "sfs_3q2-7wEXAMPLEonlyEXAMPLEonlyEXAMPLEonlyEXAMPLEo"
    }
  end

  @doc "A timestamp, optionally nullable."
  def timestamp(nullable \\ false),
    do: %Schema{type: :string, format: :"date-time", nullable: nullable}

  @doc "The inviting staff member as an invitation's recipient sees them (T9)."
  def inviter do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:first_name, :role],
      description:
        "Who invited: their first name from their account name and their role at the gym, nothing else.",
      properties: %{
        first_name: %Schema{type: :string, nullable: true},
        # `null` is listed so strict validators accept a nullable enum.
        role: %{role() | nullable: true, enum: role().enum ++ [nil]}
      }
    }
  end
end

defmodule SimpleFitWeb.Schemas.GymStaffMember do
  @moduledoc "OpenAPI schema: one staff membership in a gym's roster (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "GymStaffMember",
      description: """
      A staff membership of this gym. Only gym facts and a short name: no email, user id, profile, other gym or
      Coach–Fighter fact. A `coach` membership is the person's affiliation with this gym; their CoachProfile
      (if any) is neither required, changed nor shown.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :staff_membership_id,
        :role,
        :status,
        :name,
        :is_viewer,
        :joined_at,
        :ended_at,
        :ended_reason
      ],
      properties: %{
        staff_membership_id: %Schema{type: :string, format: :uuid},
        role: GymStaffFields.role(),
        status: %Schema{type: :string, enum: ["active", "ended"]},
        name: %Schema{
          type: :string,
          nullable: true,
          description:
            "First name and the initial of the last name (\"Natalia W.\"), from the account name; `null` without one."
        },
        is_viewer: %Schema{
          type: :boolean,
          description: "Whether this is the viewer's own membership."
        },
        joined_at: GymStaffFields.timestamp(),
        ended_at: GymStaffFields.timestamp(true),
        ended_reason: %Schema{
          type: :string,
          nullable: true,
          # `null` is listed so strict validators accept a nullable enum.
          enum: ["left", "removed", "transferred", "account_deleted", "gym_closed", nil]
        }
      },
      example: %{
        staff_membership_id: "6f1c1a3e-2b1d-4a8e-9a54-0d6b2f0c1e77",
        role: "coach",
        status: "active",
        name: "Natalia W.",
        is_viewer: false,
        joined_at: "2026-10-29T10:00:00Z",
        ended_at: nil,
        ended_reason: nil
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymStaffList do
  @moduledoc "OpenAPI schema: one page of a gym's staff (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymStaffMember}

  OpenApiSpex.schema(
    %{
      title: "GymStaffList",
      type: :object,
      additionalProperties: false,
      required: [:staff, :next_cursor],
      properties: %{
        staff: %Schema{
          type: :array,
          items: GymStaffMember,
          description: "Oldest membership first."
        },
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymStaffMemberResponse do
  @moduledoc "OpenAPI schema: one staff membership."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymStaffMember

  OpenApiSpex.schema(
    %{
      title: "GymStaffMemberResponse",
      type: :object,
      additionalProperties: false,
      required: [:staff_member],
      properties: %{staff_member: GymStaffMember}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymStaffRoleChangeRequest do
  @moduledoc "OpenAPI schema: change a staff member's role (SF-93)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "GymStaffRoleChangeRequest",
      description:
        "Only `role`; any other field (a user id, a status, a gym) is a `422 validation_error`.",
      type: :object,
      required: [:role],
      properties: %{role: GymStaffFields.assignable_role()},
      example: %{role: "front_desk"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymStaffInvitation do
  @moduledoc "OpenAPI schema: a staff invitation as its gym's administrators see it (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "GymStaffInvitation",
      description: """
      An invitation issued by this gym. The address is masked; the token and any account of the recipient are
      never shown. An invitation grants nothing until its recipient accepts it.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :invitation_id,
        :role,
        :status,
        :recipient_email,
        :invited_by,
        :created_at,
        :expires_at,
        :last_sent_at,
        :resends_remaining,
        :responded_at,
        :staff_membership_id
      ],
      properties: %{
        invitation_id: %Schema{type: :string, format: :uuid},
        role: GymStaffFields.assignable_role(),
        status: GymStaffFields.invitation_status(),
        recipient_email: %Schema{
          type: :string,
          description: "The invited address, masked (`n•••@example.com`)."
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
        responded_at: %{
          GymStaffFields.timestamp(true)
          | description: "When it was accepted, declined or cancelled."
        },
        staff_membership_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The membership an acceptance created."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymStaffInvitationList do
  @moduledoc "OpenAPI schema: one page of a gym's staff invitations (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymStaffInvitation}

  OpenApiSpex.schema(
    %{
      title: "GymStaffInvitationList",
      type: :object,
      additionalProperties: false,
      required: [:invitations, :next_cursor],
      properties: %{
        invitations: %Schema{
          type: :array,
          items: GymStaffInvitation,
          description: "Newest first."
        },
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymStaffInvitationResponse do
  @moduledoc "OpenAPI schema: one staff invitation as its gym sees it."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymStaffInvitation

  OpenApiSpex.schema(
    %{
      title: "GymStaffInvitationResponse",
      type: :object,
      additionalProperties: false,
      required: [:invitation],
      properties: %{invitation: GymStaffInvitation}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymStaffInvitationCreateRequest do
  @moduledoc "OpenAPI schema: invite an email address to a staff role (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "GymStaffInvitationCreateRequest",
      description:
        "Exactly `email` and `role`; any other field (an owner role, a gym id, a token) is a `422 validation_error`.",
      type: :object,
      required: [:email, :role],
      properties: %{
        email: %Schema{
          type: :string,
          description:
            "The address to invite; normalized like a sign-in address. Not one of the viewer's own."
        },
        role: GymStaffFields.assignable_role()
      },
      example: %{email: "natalia@example.com", role: "front_desk"}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyStaffInvitation do
  @moduledoc "OpenAPI schema: a staff invitation as its recipient sees it (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "MyStaffInvitation",
      description: """
      An invitation sent to one of the viewer's verified email addresses. Reading it changes nothing; only an
      explicit acceptance creates a staff membership.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :invitation_id,
        :status,
        :role,
        :gym,
        :invited_by,
        :sent_to,
        :created_at,
        :expires_at,
        :responded_at,
        :staff_membership_id
      ],
      properties: %{
        invitation_id: %Schema{type: :string, format: :uuid},
        status: GymStaffFields.invitation_status(),
        role: GymStaffFields.assignable_role(),
        gym: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:gym_id, :name],
          properties: %{
            gym_id: %Schema{type: :string, format: :uuid},
            name: %Schema{type: :string, nullable: true}
          }
        },
        invited_by: GymStaffFields.inviter(),
        sent_to: %Schema{
          type: :string,
          description: "The viewer's own verified address the invitation was sent to."
        },
        created_at: GymStaffFields.timestamp(),
        expires_at: GymStaffFields.timestamp(),
        responded_at: GymStaffFields.timestamp(true),
        staff_membership_id: %Schema{type: :string, format: :uuid, nullable: true}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyStaffInvitationList do
  @moduledoc "OpenAPI schema: one page of the staff invitations sent to the viewer (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, MyStaffInvitation}

  OpenApiSpex.schema(
    %{
      title: "MyStaffInvitationList",
      type: :object,
      additionalProperties: false,
      required: [:invitations, :next_cursor],
      properties: %{
        invitations: %Schema{type: :array, items: MyStaffInvitation, description: "Newest first."},
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyStaffInvitationResponse do
  @moduledoc "OpenAPI schema: one staff invitation sent to the viewer."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.MyStaffInvitation

  OpenApiSpex.schema(
    %{
      title: "MyStaffInvitationResponse",
      type: :object,
      additionalProperties: false,
      required: [:invitation],
      properties: %{invitation: MyStaffInvitation}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.StaffInvitationTokenRequest do
  @moduledoc "OpenAPI schema: a staff invitation token in a request body (SF-93)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "StaffInvitationTokenRequest",
      type: :object,
      required: [:token],
      properties: %{token: GymStaffFields.token()}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.StaffInvitationPreview do
  @moduledoc "OpenAPI schema: what an E06 link shows before sign-in (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymStaffFields

  OpenApiSpex.schema(
    %{
      title: "StaffInvitationPreview",
      description: """
      Only the gym's name, the role, the inviter's first name and role, and the expiry (T9). Nothing about the
      recipient, the address or any account.
      """,
      type: :object,
      additionalProperties: false,
      required: [:gym, :role, :invited_by, :expires_at],
      properties: %{
        gym: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:name],
          properties: %{name: %Schema{type: :string, nullable: true}}
        },
        role: GymStaffFields.assignable_role(),
        invited_by: GymStaffFields.inviter(),
        expires_at: GymStaffFields.timestamp()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.StaffInvitationPreviewResponse do
  @moduledoc "OpenAPI schema: an E06 link's preview."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.StaffInvitationPreview

  OpenApiSpex.schema(
    %{
      title: "StaffInvitationPreviewResponse",
      type: :object,
      additionalProperties: false,
      required: [:preview],
      properties: %{preview: StaffInvitationPreview}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.StaffInvitationAcceptResponse do
  @moduledoc "OpenAPI schema: the result of accepting a staff invitation (SF-93)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymStaffFields, MyStaffInvitation}

  OpenApiSpex.schema(
    %{
      title: "StaffInvitationAcceptResponse",
      description: """
      The consumed invitation and the active staff membership it created. The gym now appears among the
      viewer's gym workspaces (`resolveMyEntry`, `listMyGyms`); nothing switches the viewer's current context.
      """,
      type: :object,
      additionalProperties: false,
      required: [:invitation, :gym_id, :staff_membership_id, :role, :outcome],
      properties: %{
        invitation: MyStaffInvitation,
        gym_id: %Schema{type: :string, format: :uuid},
        staff_membership_id: %Schema{type: :string, format: :uuid},
        role: GymStaffFields.assignable_role(),
        outcome: %Schema{
          type: :string,
          enum: ["accepted", "already_accepted"],
          description:
            "`already_accepted`: the viewer accepted it before (a repeated request); nothing changed."
        }
      }
    },
    struct?: false
  )
end
