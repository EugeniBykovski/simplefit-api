defmodule SimpleFit.Accounts.SecurityEvent do
  @moduledoc """
  An append-only account security event (SF-157): a password was set, changed or
  reset, and in which session when there was one. No address, password or IP.
  Internal to `SimpleFit.Accounts`.
  """

  use Ecto.Schema

  @type event :: :password_set | :password_changed | :password_reset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          event: event() | nil,
          session_id: Ecto.UUID.t() | nil,
          occurred_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "account_security_events" do
    field :user_id, :binary_id
    field :event, Ecto.Enum, values: [:password_set, :password_changed, :password_reset]
    field :session_id, :binary_id
    field :occurred_at, :utc_datetime_usec
  end
end
