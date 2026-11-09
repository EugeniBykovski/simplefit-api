defmodule SimpleFitWeb.Schemas.OperatorSecurityKeys do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorSecurityKeys",
    description:
      "Security keys the operator has registered, and how many the policy requires to be active.",
    type: :object,
    required: [:registered, :required],
    properties: %{
      registered: %OpenApiSpex.Schema{type: :integer, minimum: 0},
      required: %OpenApiSpex.Schema{type: :integer, minimum: 1}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorStepUp do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OperatorStepUp",
    description:
      "The security-key check of this session. Valid only in this session, until `expires_at`. " <>
        "High-risk actions also need `fresh_seconds_remaining > 0`.",
    type: :object,
    required: [:verified_at, :expires_at, :fresh_seconds_remaining],
    properties: %{
      verified_at: %Schema{type: :string, format: :"date-time"},
      expires_at: %Schema{type: :string, format: :"date-time"},
      fresh_seconds_remaining: %Schema{type: :integer, minimum: 0}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorSelf do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{OperatorSecurityKeys, OperatorStepUp}

  OpenApiSpex.schema(%{
    title: "OperatorSelf",
    description:
      "The viewer's own operator state. `permissions` lists what is granted while `active`; it is empty " <>
        "otherwise. Holding a permission still requires `step_up` at request time.",
    type: :object,
    required: [
      :id,
      :status,
      :permissions,
      :security_keys,
      :step_up,
      :enrollment_expires_at,
      :activated_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      status: %Schema{type: :string, enum: ["pending_enrollment", "active"]},
      permissions: %Schema{type: :array, items: %Schema{type: :string}},
      security_keys: OperatorSecurityKeys,
      step_up: %Schema{type: :object, allOf: [OperatorStepUp], nullable: true},
      enrollment_expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
      activated_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorSelfResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorSelfResponse",
    type: :object,
    required: [:operator],
    properties: %{operator: SimpleFitWeb.Schemas.OperatorSelf}
  })
end

defmodule SimpleFitWeb.Schemas.OperatorCredential do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OperatorCredential",
    description: "A registered security key. Metadata only: no key material.",
    type: :object,
    required: [:id, :label, :created_at, :last_used_at, :revoked_at, :revoked_reason],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      label: %Schema{type: :string},
      created_at: %Schema{type: :string, format: :"date-time"},
      last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
      revoked_at: %Schema{type: :string, format: :"date-time", nullable: true},
      revoked_reason: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorCredentialResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorCredentialResponse",
    type: :object,
    required: [:credential],
    properties: %{credential: SimpleFitWeb.Schemas.OperatorCredential}
  })
end

defmodule SimpleFitWeb.Schemas.OperatorCredentialListResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorCredentialListResponse",
    type: :object,
    required: [:credentials],
    properties: %{
      credentials: %OpenApiSpex.Schema{
        type: :array,
        items: SimpleFitWeb.Schemas.OperatorCredential
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorCredentialRegistered do
  @moduledoc false
  require OpenApiSpex
  alias SimpleFitWeb.Schemas.{OperatorCredential, OperatorSecurityKeys}

  OpenApiSpex.schema(%{
    title: "OperatorCredentialRegistered",
    type: :object,
    required: [:credential, :status, :security_keys],
    properties: %{
      credential: OperatorCredential,
      status: %OpenApiSpex.Schema{type: :string, enum: ["pending_enrollment", "active"]},
      security_keys: OperatorSecurityKeys
    }
  })
end

defmodule SimpleFitWeb.Schemas.WebAuthnOptionsResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "WebAuthnOptionsResponse",
    description:
      "A one-time challenge. `public_key` is the WebAuthn JSON form (camelCase, base64url values) for " <>
        "`PublicKeyCredential.parseCreationOptionsFromJSON` or `parseRequestOptionsFromJSON`. " <>
        "Answer within its `timeout`, in this session only.",
    type: :object,
    required: [:challenge_id, :public_key],
    properties: %{
      challenge_id: %Schema{type: :string, format: :uuid},
      public_key: %Schema{type: :object, additionalProperties: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.RegisterOperatorCredentialRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RegisterOperatorCredentialRequest",
    description: "The authenticator's registration response, base64url-encoded.",
    type: :object,
    required: [:challenge_id, :attestation_object, :client_data_json, :label],
    properties: %{
      challenge_id: %Schema{type: :string, format: :uuid},
      attestation_object: %Schema{type: :string, maxLength: 16_384},
      client_data_json: %Schema{type: :string, maxLength: 16_384},
      label: %Schema{type: :string, minLength: 1, maxLength: 60}
    }
  })
end

defmodule SimpleFitWeb.Schemas.VerifyOperatorStepUpRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VerifyOperatorStepUpRequest",
    description: "The authenticator's assertion response, base64url-encoded.",
    type: :object,
    required: [:challenge_id, :credential_id, :authenticator_data, :client_data_json, :signature],
    properties: %{
      challenge_id: %Schema{type: :string, format: :uuid},
      credential_id: %Schema{type: :string, maxLength: 16_384},
      authenticator_data: %Schema{type: :string, maxLength: 16_384},
      client_data_json: %Schema{type: :string, maxLength: 16_384},
      signature: %Schema{type: :string, maxLength: 16_384}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorStepUpResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorStepUpResponse",
    type: :object,
    required: [:step_up],
    properties: %{step_up: SimpleFitWeb.Schemas.OperatorStepUp}
  })
end

defmodule SimpleFitWeb.Schemas.OperatorSummary do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OperatorSummary",
    description: "An operator as other operators see it. Ids only: no names or email addresses.",
    type: :object,
    required: [
      :id,
      :user_id,
      :status,
      :bootstrap,
      :created_by_operator_id,
      :permissions,
      :security_keys,
      :enrollment_expires_at,
      :activated_at,
      :suspended_at,
      :revoked_at,
      :created_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      user_id: %Schema{type: :string, format: :uuid},
      status: %Schema{
        type: :string,
        enum: ["pending_enrollment", "active", "suspended", "revoked"]
      },
      bootstrap: %Schema{type: :boolean},
      created_by_operator_id: %Schema{type: :string, format: :uuid, nullable: true},
      permissions: %Schema{type: :array, items: %Schema{type: :string}},
      security_keys: SimpleFitWeb.Schemas.OperatorSecurityKeys,
      enrollment_expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
      activated_at: %Schema{type: :string, format: :"date-time", nullable: true},
      suspended_at: %Schema{type: :string, format: :"date-time", nullable: true},
      revoked_at: %Schema{type: :string, format: :"date-time", nullable: true},
      created_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorSummaryResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorSummaryResponse",
    type: :object,
    required: [:operator],
    properties: %{operator: SimpleFitWeb.Schemas.OperatorSummary}
  })
end

defmodule SimpleFitWeb.Schemas.OperatorListResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorListResponse",
    type: :object,
    required: [:operators],
    properties: %{
      operators: %OpenApiSpex.Schema{type: :array, items: SimpleFitWeb.Schemas.OperatorSummary}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorActionRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OperatorActionRequest",
    description:
      "A reason code and a client-generated operation id. Repeating an operation id changes nothing.",
    type: :object,
    required: [:reason_code, :operation_id],
    properties: %{
      reason_code: %Schema{type: :string, pattern: "^[a-z][a-z0-9_]{1,59}$"},
      operation_id: %Schema{type: :string, format: :uuid}
    }
  })
end

defmodule SimpleFitWeb.Schemas.ProvisionOperatorRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ProvisionOperatorRequest",
    description:
      "An existing account (by user id, never by email) with completed registration, and the exact permissions.",
    type: :object,
    required: [:user_id, :permissions, :reason_code, :operation_id],
    properties: %{
      user_id: %Schema{type: :string, format: :uuid},
      permissions: %Schema{type: :array, minItems: 1, items: %Schema{type: :string}},
      reason_code: %Schema{type: :string, pattern: "^[a-z][a-z0-9_]{1,59}$"},
      operation_id: %Schema{type: :string, format: :uuid}
    }
  })
end

defmodule SimpleFitWeb.Schemas.GrantOperatorPermissionRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Operators.Policy

  OpenApiSpex.schema(%{
    title: "GrantOperatorPermissionRequest",
    type: :object,
    required: [:permission, :reason_code, :operation_id],
    properties: %{
      permission: %Schema{type: :string, enum: Policy.permissions()},
      reason_code: %Schema{type: :string, pattern: "^[a-z][a-z0-9_]{1,59}$"},
      operation_id: %Schema{type: :string, format: :uuid}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorAuditEvent do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OperatorAuditEvent",
    description: "An append-only operator security event. Ids and codes only.",
    type: :object,
    required: [:id, :occurred_at, :action, :outcome, :authority],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      occurred_at: %Schema{type: :string, format: :"date-time"},
      action: %Schema{type: :string},
      outcome: %Schema{type: :string, enum: ["allowed", "refused"]},
      authority: %Schema{
        type: :string,
        enum: ["platform_operator", "signed_ceremony", "local_development_ceremony", "system"]
      },
      actor_operator_id: %Schema{type: :string, format: :uuid, nullable: true},
      actor_user_id: %Schema{type: :string, format: :uuid, nullable: true},
      permission: %Schema{type: :string, nullable: true},
      target_type: %Schema{type: :string, nullable: true},
      target_id: %Schema{type: :string, format: :uuid, nullable: true},
      reason_code: %Schema{type: :string, nullable: true},
      operation_id: %Schema{type: :string, format: :uuid, nullable: true},
      session_id: %Schema{type: :string, format: :uuid, nullable: true},
      ceremony_id: %Schema{type: :string, format: :uuid, nullable: true},
      request_id: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorAuditEventListResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorAuditEventListResponse",
    type: :object,
    required: [:events],
    properties: %{
      events: %OpenApiSpex.Schema{type: :array, items: SimpleFitWeb.Schemas.OperatorAuditEvent}
    }
  })
end
