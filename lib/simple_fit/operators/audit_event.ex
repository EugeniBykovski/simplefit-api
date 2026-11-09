defmodule SimpleFit.Operators.AuditEvent do
  @moduledoc """
  An append-only record of an operator security event, allowed or refused
  (SF-110). Ids and codes only: no emails, names, challenges, keys, tokens or
  request bodies. No foreign keys, so events outlive what they name.

  SF-111 admin actions write exactly one event per attempt by an identified
  operator: `command` is the action id, `outcome` says how it ended (`allowed`,
  `refused` before anything changed, `conflict` with the current state, `invalid`
  input or confirmation, `failed` mutation) and `result_code` why. `from_state`,
  `to_state`, `revision` and `confirmation_id` summarise an allowed change.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "operator_audit_events" do
    field :occurred_at, :utc_datetime_usec
    field :action, :string
    field :outcome, Ecto.Enum, values: [:allowed, :refused, :conflict, :invalid, :failed]

    field :authority, Ecto.Enum,
      values: [:platform_operator, :signed_ceremony, :local_development_ceremony, :system]

    field :actor_operator_id, :binary_id
    field :actor_user_id, :binary_id
    field :permission, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :reason_code, :string
    field :operation_id, :binary_id
    field :session_id, :binary_id
    field :ceremony_id, :binary_id
    field :request_id, :string
    field :command, :string
    field :result_code, :string
    field :from_state, :string
    field :to_state, :string
    field :revision, :integer
    field :confirmation_id, :binary_id
  end
end
