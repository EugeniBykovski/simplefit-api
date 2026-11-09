defmodule SimpleFit.Entry.ContextChoice do
  @moduledoc """
  The user's last explicitly chosen application context (ADR 0017, SF-51):
  `:fighter`, `:coach` or, with its `gym_id`, `:gym` (SF-84), or with its
  `sponsor_organization_id`, `:sponsor` (SF-112). One row per
  user, written only by an explicit choice
  (`SimpleFit.Entry.record_context_choice/2`), never by resolving the entry.
  A navigation preference: the resolver uses it only while that profile is
  still completed, that gym is still completed and the user active staff
  there, or that sponsor organization is still active and the user an active
  member. It is per user, not per session or tab: every request still names
  its own gym in the path.
  """

  use Ecto.Schema

  alias SimpleFit.Accounts.User

  @contexts [:fighter, :coach, :gym, :sponsor]

  @type context :: :fighter | :coach | :gym | :sponsor
  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          context: context() | nil,
          gym_id: Ecto.UUID.t() | nil,
          sponsor_organization_id: Ecto.UUID.t() | nil,
          chosen_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "entry_context_choices" do
    belongs_to :user, User, primary_key: true
    field :context, Ecto.Enum, values: @contexts
    field :gym_id, :binary_id
    field :sponsor_organization_id, :binary_id
    field :chosen_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The contexts a user can choose between."
  @spec contexts() :: [context()]
  def contexts, do: @contexts
end
