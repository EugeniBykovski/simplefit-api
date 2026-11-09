defmodule SimpleFit.Operators.Challenge do
  @moduledoc """
  A WebAuthn challenge issued by the server for one operator and one session.
  Consumed at most once, by an atomic update (`SimpleFit.Operators`).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "operator_webauthn_challenges" do
    field :operator_id, :binary_id
    field :session_id, :binary_id
    field :purpose, Ecto.Enum, values: [:registration, :step_up]
    field :challenge, :binary, redact: true
    field :issued_at, :integer
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end
end
