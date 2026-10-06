defmodule SimpleFit.Accounts.User do
  @moduledoc """
  The one global SimpleFit user (ADR 0009).

  A person has exactly one user, whatever they do in SimpleFit. Roles are not
  attributes of the user: fighter and coach profiles, gym and sponsor
  workspace memberships and staff access are separate records added by their
  own tickets. The user is signed in through its `SimpleFit.Accounts.Identity`
  records.
  """

  use Ecto.Schema

  alias SimpleFit.Accounts.Identity

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          identities: [Identity.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "users" do
    has_many :identities, Identity

    timestamps()
  end
end
