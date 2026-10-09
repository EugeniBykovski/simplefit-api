defmodule SimpleFit.FirstRun.Outcome do
  @moduledoc """
  How a user left a one-time first-run experience (ADR 0018): `:completed`
  (finished it) or `:dismissed` (ended it early). One per user and
  experience, never updated: the first outcome recorded is final.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SimpleFit.Accounts.User

  @experiences [:fighter_web_tour]
  @outcomes [:completed, :dismissed]

  @type experience :: :fighter_web_tour
  @type outcome :: :completed | :dismissed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          experience: experience() | nil,
          outcome: outcome() | nil,
          recorded_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "first_run_outcomes" do
    belongs_to :user, User

    field :experience, Ecto.Enum, values: @experiences
    field :outcome, Ecto.Enum, values: @outcomes
    field :recorded_at, :utc_datetime_usec
  end

  @doc "The first-run experiences an outcome can be recorded for."
  @spec experiences() :: [experience()]
  def experiences, do: @experiences

  @doc "The outcomes of an experience."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "Validates the outcome sent by the client (`outcome`, string or atom key)."
  @spec record_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def record_changeset(%__MODULE__{} = outcome, attrs, now) do
    outcome
    |> cast(attrs, [:outcome])
    |> validate_required([:outcome])
    |> put_change(:recorded_at, now)
    |> unique_constraint([:user_id, :experience],
      name: :first_run_outcomes_user_id_experience_index
    )
  end
end
