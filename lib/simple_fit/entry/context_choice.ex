defmodule SimpleFit.Entry.ContextChoice do
  @moduledoc """
  The user's last explicitly chosen application context (ADR 0017, SF-51):
  `:fighter` or `:coach`. One row per user, written only by an explicit
  choice (`SimpleFit.Entry.record_context_choice/2`), never by resolving the
  entry. A navigation preference: the resolver uses it only while that
  context is still completed.
  """

  use Ecto.Schema

  alias SimpleFit.Accounts.User

  @contexts [:fighter, :coach]

  @type context :: :fighter | :coach
  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          context: context() | nil,
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
    field :chosen_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The profile contexts a user can choose between."
  @spec contexts() :: [context()]
  def contexts, do: @contexts
end
