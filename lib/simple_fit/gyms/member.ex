defmodule SimpleFit.Gyms.Member do
  @moduledoc """
  A user's membership of one gym as a participant (ADR 0026, D-G07, D-G08;
  SF-95): someone who trains there. Independent of staff memberships (a
  staff member may also be a member, in another row), of Fighter and Coach
  profiles and of Coach–Fighter relationships: nothing here refers to them,
  and a gym membership grants no gym permission (`SimpleFit.Gyms.Policy`
  reads staff memberships only) and no gym workspace.

  ## Lifecycle

    * `:requested` - a join-code request waiting for the gym's staff;
    * `:active` - approved, auto-approved (the gym's explicit setting) or
      accepted from a member invitation;
    * `:rejected` - a request the staff declined (final);
    * `:cancelled` - a request its requester withdrew (final);
    * `:ended` - an active membership that ended (`:left` or `:removed`;
      final).

  At most one requested-or-active row per gym and user (a partial unique
  index); re-enrolling after a final row creates a new one, so the history
  is kept. The database enforces the transitions, the timestamps of each
  status, and that rows are never deleted. A final row keeps its history
  when its user is deleted (`user_id` becomes `nil`); a requested or active
  one blocks the deletion.
  """

  use Ecto.Schema

  @type status :: :requested | :active | :ended | :rejected | :cancelled
  @type joined_via :: :join_code | :invitation
  @type ended_reason :: :left | :removed | :account_deleted | :gym_closed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          gym_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          status: status() | nil,
          joined_via: joined_via() | nil,
          auto_approved: boolean() | nil,
          requested_at: DateTime.t() | nil,
          activated_at: DateTime.t() | nil,
          responded_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          ended_reason: ended_reason() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses [:requested, :active, :ended, :rejected, :cancelled]
  @ended_reasons [:left, :removed, :account_deleted, :gym_closed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gym_members" do
    field :gym_id, :binary_id
    field :user_id, :binary_id
    field :status, Ecto.Enum, values: @statuses
    field :joined_via, Ecto.Enum, values: [:join_code, :invitation]
    field :auto_approved, :boolean, default: false
    field :requested_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec
    field :responded_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :ended_reason, Ecto.Enum, values: @ended_reasons

    timestamps()
  end

  @doc "Every status."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Every end reason."
  @spec ended_reasons() :: [ended_reason()]
  def ended_reasons, do: @ended_reasons
end
