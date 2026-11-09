defmodule SimpleFitWeb.Schemas.SponsorOrganization do
  @moduledoc "OpenAPI schema: a sponsor organization as its members see it (SF-112)."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorOrganization",
      description: """
      An approved sponsor organization. No verification, plan, contract, subscription or other commercial state
      exists: approval grants none (ADR 0030).
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :sponsor_id,
        :legal_name,
        :display_name,
        :country_code,
        :website,
        :status,
        :revision,
        :created_at
      ],
      properties: %{
        sponsor_id: %Schema{type: :string, format: :uuid},
        legal_name: %Schema{type: :string},
        display_name: %Schema{type: :string},
        country_code: %Schema{type: :string, pattern: "^[A-Z]{2}$"},
        website: %Schema{type: :string, nullable: true},
        status: %Schema{
          type: :string,
          enum: ["active", "suspended"],
          description:
            "`suspended`: read-only for its members. A closed organization is not found."
        },
        revision: %Schema{type: :integer, minimum: 1},
        created_at: %Schema{type: :string, format: :"date-time"}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorViewerMembership do
  @moduledoc "OpenAPI schema: the viewer's own membership of a sponsor organization (SF-112)."

  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Sponsors.Policy

  OpenApiSpex.schema(
    %{
      title: "SponsorViewerMembership",
      type: :object,
      additionalProperties: false,
      required: [:membership_id, :role, :permissions, :joined_at],
      properties: %{
        membership_id: %Schema{type: :string, format: :uuid},
        role: %Schema{type: :string, enum: ["owner", "manager", "member"]},
        permissions: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: Enum.map(Policy.permissions(), &Atom.to_string/1)},
          description:
            "For display only: every operation checks the viewer's active membership and role again."
        },
        joined_at: %Schema{type: :string, format: :"date-time"}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorOrganizationResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "SponsorOrganizationResponse",
      type: :object,
      additionalProperties: false,
      required: [:organization, :membership],
      properties: %{
        organization: SimpleFitWeb.Schemas.SponsorOrganization,
        membership: SimpleFitWeb.Schemas.SponsorViewerMembership
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorOrganizationListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorOrganizationListResponse",
      type: :object,
      additionalProperties: false,
      required: [:organizations],
      properties: %{
        organizations: %Schema{
          type: :array,
          items: SimpleFitWeb.Schemas.SponsorOrganizationResponse,
          description:
            "The viewer's active memberships of organizations that aren't closed, oldest membership first."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorMember do
  @moduledoc "OpenAPI schema: a member of a sponsor organization, as colleagues see them (SF-112)."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorMember",
      description:
        "The short account name only: never an email, full name or other account field.",
      type: :object,
      additionalProperties: false,
      required: [:membership_id, :short_name, :role, :status, :joined_at, :is_viewer],
      properties: %{
        membership_id: %Schema{type: :string, format: :uuid},
        short_name: %Schema{type: :string, nullable: true},
        role: %Schema{type: :string, enum: ["owner", "manager", "member"]},
        status: %Schema{type: :string, enum: ["active", "suspended"]},
        joined_at: %Schema{type: :string, format: :"date-time"},
        is_viewer: %Schema{type: :boolean}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorMemberListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorMemberListResponse",
      type: :object,
      additionalProperties: false,
      required: [:members, :next_cursor],
      properties: %{
        members: %Schema{type: :array, items: SimpleFitWeb.Schemas.SponsorMember},
        next_cursor: %Schema{type: :string, nullable: true}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorContact do
  @moduledoc "OpenAPI schema: a business contact of a sponsor organization (SF-112)."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorContact",
      description: "A business contact. Not an account and not a member: it grants no access.",
      type: :object,
      additionalProperties: false,
      required: [:contact_id, :kind, :full_name, :job_title, :email, :phone],
      properties: %{
        contact_id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: ["primary", "additional"]},
        full_name: %Schema{type: :string},
        job_title: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string},
        phone: %Schema{type: :string, nullable: true}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.SponsorContactListResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SponsorContactListResponse",
      type: :object,
      additionalProperties: false,
      required: [:contacts],
      properties: %{
        contacts: %Schema{type: :array, items: SimpleFitWeb.Schemas.SponsorContact}
      }
    },
    struct?: false
  )
end
