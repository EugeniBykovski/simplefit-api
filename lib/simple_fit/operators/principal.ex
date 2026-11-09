defmodule SimpleFit.Operators.Principal do
  @moduledoc """
  An operator authorized for one request (SF-110): resolved from the session on the
  server, never from anything the client sends. An answer, not a pass.
  """

  @enforce_keys [:operator_id, :user_id, :session_id]
  defstruct [:operator_id, :user_id, :session_id]

  @type t :: %__MODULE__{
          operator_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t()
        }
end
