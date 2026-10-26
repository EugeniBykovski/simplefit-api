defmodule SimpleFit.Gyms.StaffMembership do
  @moduledoc """
  A user's staff (workspace) membership at one gym, with one fixed role
  (ADR 0026, D-G03): `:owner`, `:manager`, `:coach` or `:front_desk`. It is
  the only source of gym permissions (`SimpleFit.Gyms.Policy`) and is not a
  gym *participant* membership (a member who trains there, SF-89) nor a
  Coach–Fighter relationship.

  `:active` until it ends (`:ended`, final) with a reason. The database
  allows at most one active membership per user and gym and exactly one
  active owner per gym (checked at commit). An ended membership keeps its
  history when its user is deleted (`user_id` becomes `nil`); an active one
  blocks the deletion.
  """

  use Ecto.Schema

  alias SimpleFit.Gyms.Gym

  @type role :: :owner | :manager | :coach | :front_desk
  @type ended_reason :: :left | :removed | :transferred | :account_deleted | :gym_closed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          role: role() | nil,
          status: :active | :ended | nil,
          ended_at: DateTime.t() | nil,
          ended_reason: ended_reason() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @roles [:owner, :manager, :coach, :front_desk]
  @ended_reasons [:left, :removed, :transferred, :account_deleted, :gym_closed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_staff_memberships" do
    belongs_to :gym, Gym
    field :user_id, :binary_id
    field :role, Ecto.Enum, values: @roles
    field :status, Ecto.Enum, values: [:active, :ended]
    field :ended_at, :utc_datetime_usec
    field :ended_reason, Ecto.Enum, values: @ended_reasons

    timestamps()
  end

  @doc "The staff roles (D-G03)."
  @spec roles() :: [role()]
  def roles, do: @roles
end
