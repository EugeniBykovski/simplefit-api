defmodule SimpleFit.Accounts.AccountConsent do
  @moduledoc """
  One consent decision of a user (ADR 0016). The table is an append-only
  history: a decision is never updated, a later record supersedes it.

    * `:terms` and `:privacy` are required legal consents: always
      `:accepted`, always with the `document_version` accepted.
    * `:product_news` is an optional preference without a document version:
      `:accepted` subscribes, `:withdrawn` unsubscribes.

  Only kind, version, decision and time are stored: no IP address, device or
  free text.
  """

  use Ecto.Schema

  alias SimpleFit.Accounts.User

  @required_kinds [:terms, :privacy]
  @kinds [:terms, :privacy, :product_news]

  @type kind :: :terms | :privacy | :product_news
  @type decision :: :accepted | :withdrawn

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          kind: kind() | nil,
          document_version: String.t() | nil,
          decision: decision() | nil,
          recorded_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "account_consents" do
    belongs_to :user, User

    field :kind, Ecto.Enum, values: @kinds
    field :document_version, :string
    field :decision, Ecto.Enum, values: [:accepted, :withdrawn]
    field :recorded_at, :utc_datetime_usec
  end

  @doc "Consents required to complete registration."
  @spec required_kinds() :: [kind()]
  def required_kinds, do: @required_kinds
end
