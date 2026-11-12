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
    description: """
    An operator as other operators see it: ids, the account's short name (first name and an initial, SF-129)
    and never an email address. `grants` lists each active permission with where it came from;
    `last_key_check_at` is when the operator last completed a security-key check (null: never).
    """,
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
      :created_at,
      :revision
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      user_id: %Schema{type: :string, format: :uuid},
      revision: %Schema{
        type: :integer,
        minimum: 1,
        description:
          "The operator's authority state (status and permissions) as a number. Admin actions send it as `expected_revision`; a stale one is `409 revision_conflict` (SF-111)."
      },
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
      created_at: %Schema{type: :string, format: :"date-time"},
      short_name: %Schema{
        type: :string,
        nullable: true,
        description: "First name and an initial."
      },
      last_key_check_at: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "The operator's last completed security-key check."
      },
      grants: %Schema{
        type: :array,
        description: "Active permissions with their provenance (empty for a revoked operator).",
        items: %Schema{
          type: :object,
          required: [:permission, :granted_at, :granted_by_operator_id, :reason_code, :bootstrap],
          properties: %{
            permission: %Schema{type: :string},
            granted_at: %Schema{type: :string, format: :"date-time"},
            granted_by_operator_id: %Schema{type: :string, format: :uuid, nullable: true},
            reason_code: %Schema{type: :string, nullable: true},
            bootstrap: %Schema{
              type: :boolean,
              description: "Granted by the founder bootstrap ceremony, not by an operator."
            }
          }
        }
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorPermissionCatalogResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OperatorPermissionCatalogResponse",
    description: """
    Every operator permission (SF-129): the catalog the database also enforces, each with the key-check
    assurance it needs (`key`: a current check; `fresh_key`: one in the last minutes). No role, bundle or
    superuser exists: permissions are granted one by one.
    """,
    type: :object,
    required: [:permissions],
    properties: %{
      permissions: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          required: [:permission, :assurance],
          properties: %{
            permission: %Schema{type: :string},
            assurance: %Schema{type: :string, enum: ["key", "fresh_key"]}
          }
        }
      }
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
      "An existing account with completed registration, named by exactly one of `user_id` or an exact `email` " <>
        "(SF-129; never part of either), and the exact permissions.",
    type: :object,
    required: [:permissions, :reason_code, :operation_id],
    properties: %{
      user_id: %Schema{type: :string, format: :uuid},
      email: %Schema{
        type: :string,
        maxLength: 320,
        description: "The account's exact email address."
      },
      permissions: %Schema{type: :array, minItems: 1, items: %Schema{type: :string}},
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
      outcome: %Schema{
        type: :string,
        enum: ["allowed", "refused", "conflict", "invalid", "failed"],
        description:
          "`allowed`; `refused` before anything changed; `conflict` with the current state; `invalid` input or confirmation; `failed` mutation (SF-111)."
      },
      command: %Schema{
        type: :string,
        nullable: true,
        description: "The admin action or read projection id (SF-111)."
      },
      result_code: %Schema{
        type: :string,
        nullable: true,
        description: "Why an attempt didn't succeed, e.g. `step_up_required`, `revision_stale`."
      },
      from_state: %Schema{type: :string, nullable: true},
      to_state: %Schema{type: :string, nullable: true},
      revision: %Schema{
        type: :integer,
        nullable: true,
        description: "The target's revision after an allowed change."
      },
      confirmation_id: %Schema{type: :string, format: :uuid, nullable: true},
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
    required: [:events, :next_cursor],
    properties: %{
      events: %OpenApiSpex.Schema{type: :array, items: SimpleFitWeb.Schemas.OperatorAuditEvent},
      next_cursor: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Opaque. Valid only with the same filters, for the same operator, for an hour. `null` on the last page."
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorAuditEventResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OperatorAuditEventResponse",
    type: :object,
    required: [:event],
    properties: %{event: SimpleFitWeb.Schemas.OperatorAuditEvent}
  })
end

defmodule SimpleFitWeb.Schemas.OperatorActionPreviewResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias SimpleFit.Operators.Actions

  OpenApiSpex.schema(%{
    title: "OperatorActionPreviewResponse",
    description:
      "What an admin action would do now (SF-111). Authorizes nothing: execution checks everything again.",
    type: :object,
    required: [:preview],
    properties: %{
      preview: %Schema{
        type: :object,
        required: [
          :action,
          :target,
          :expected_revision,
          :current_state,
          :proposed_state,
          :permission,
          :impact,
          :required_permission,
          :required_assurance,
          :reason_code,
          :confirmation
        ],
        properties: %{
          action: %Schema{type: :string, enum: Actions.ids()},
          target: %Schema{
            type: :object,
            required: [:type, :id, :status],
            properties: %{
              type: %Schema{type: :string},
              id: %Schema{type: :string, format: :uuid},
              status: %Schema{type: :string}
            }
          },
          expected_revision: %Schema{
            type: :integer,
            minimum: 1,
            description: "Send it unchanged with the execution."
          },
          current_state: %Schema{type: :string},
          proposed_state: %Schema{type: :string},
          permission: %Schema{type: :string, nullable: true},
          impact: %Schema{
            type: :array,
            items: %Schema{type: :string},
            description: "Codes, e.g. `access_blocked`, `irreversible`."
          },
          required_permission: %Schema{type: :string},
          required_assurance: %Schema{type: :string, enum: ["key", "fresh_key"]},
          reason_code: %Schema{type: :string},
          confirmation: %Schema{
            type: :object,
            required: [:required, :token, :expires_at],
            properties: %{
              required: %Schema{type: :boolean},
              token: %Schema{
                type: :string,
                nullable: true,
                description:
                  "One-time, for this operator, session, action, target, parameters and revision only. Send it as `confirmation_token`. Shown once; never logged."
              },
              expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
            }
          }
        }
      }
    }
  })
end

defmodule SimpleFitWeb.Schemas.OperatorActionSchemas do
  @moduledoc """
  Request bodies of the SF-111 admin actions, built from their declarations
  (`SimpleFit.Operators.OperatorActions`) so the documented reason codes and fields
  are the ones the pipeline accepts.
  """

  alias OpenApiSpex.Schema
  alias SimpleFit.Operators.{Actions, Policy}

  @doc "The body of `phase` (`:preview` or `:execute`) of `action_id`; `body_params` are the action's own body fields."
  @spec body(String.t(), :preview | :execute, String.t(), [atom()]) :: map()
  def body(action_id, phase, title, body_params) do
    action = Actions.fetch!(action_id)

    common = %{
      reason_code: %Schema{
        type: :string,
        enum: action.reasons,
        description: "Why. A code from this action's list; no free text."
      },
      expected_revision: %Schema{
        type: :integer,
        minimum: 1,
        description:
          if(phase == :preview,
            do: "Optional: the revision you saw. A stale one is `409 revision_conflict`.",
            else:
              "The `revision` you saw (from the preview or the operator). A stale one is `409 revision_conflict`."
          )
      }
    }

    execute = %{
      operation_id: %Schema{
        type: :string,
        format: :uuid,
        description:
          "Client-generated per intended change. Repeating the same request with it changes nothing and answers with the current state; using it for another request is `409 conflict`."
      },
      confirmation_token: %Schema{
        type: :string,
        description:
          "From this action's preview. Required when the action needs confirmation (`428 confirmation_required` without it, `422 confirmation_invalid` when it doesn't match, expired or was used)."
      }
    }

    own = Map.new(body_params, &{&1, %Schema{type: :string, enum: Policy.permissions()}})

    properties =
      if phase == :execute,
        do: common |> Map.merge(execute) |> Map.merge(own),
        else: Map.merge(common, own)

    required =
      body_params ++
        [:reason_code] ++
        if(phase == :execute, do: [:expected_revision, :operation_id], else: []) ++
        if(phase == :execute and action.confirmation == :required,
          do: [:confirmation_token],
          else: []
        )

    %{
      title: title,
      type: :object,
      required: required,
      properties: properties
    }
  end
end

for {module, action_id, phase, body_params} <- [
      {SimpleFitWeb.Schemas.GrantOperatorPermissionRequest, "operator.permission.grant", :execute,
       [:permission]},
      {SimpleFitWeb.Schemas.GrantOperatorPermissionPreviewRequest, "operator.permission.grant",
       :preview, [:permission]},
      {SimpleFitWeb.Schemas.RevokeOperatorPermissionRequest, "operator.permission.revoke",
       :execute, []},
      {SimpleFitWeb.Schemas.RevokeOperatorPermissionPreviewRequest, "operator.permission.revoke",
       :preview, []},
      {SimpleFitWeb.Schemas.SuspendOperatorRequest, "operator.suspend", :execute, []},
      {SimpleFitWeb.Schemas.SuspendOperatorPreviewRequest, "operator.suspend", :preview, []},
      {SimpleFitWeb.Schemas.ReinstateOperatorRequest, "operator.reinstate", :execute, []},
      {SimpleFitWeb.Schemas.ReinstateOperatorPreviewRequest, "operator.reinstate", :preview, []},
      {SimpleFitWeb.Schemas.RevokeOperatorRequest, "operator.revoke", :execute, []},
      {SimpleFitWeb.Schemas.RevokeOperatorPreviewRequest, "operator.revoke", :preview, []}
    ] do
  title = module |> Module.split() |> List.last()

  schema = SimpleFitWeb.Schemas.OperatorActionSchemas.body(action_id, phase, title, body_params)

  defmodule module do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(schema)
  end
end
