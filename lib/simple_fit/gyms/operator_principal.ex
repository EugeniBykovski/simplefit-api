defmodule SimpleFit.Gyms.OperatorPrincipal do
  @moduledoc """
  An operator as `SimpleFit.Gyms.VerificationAuthority` authenticated them for
  one call (SF-136): an immutable actor id from the authority, never an email,
  and the person's user id so conflicts of interest are checked on identity.

  It is an answer, not a pass. `SimpleFit.Gyms.VerificationReview` takes a
  credential and asks the authority again on every call, so a struct built by
  hand opens nothing.
  """

  @enforce_keys [:actor_id, :user_id, :authority]
  defstruct [:actor_id, :user_id, :authority]

  @type t :: %__MODULE__{
          actor_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          authority: :local_fixture
        }
end
