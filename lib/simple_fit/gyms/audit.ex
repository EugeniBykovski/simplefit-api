defmodule SimpleFit.Gyms.Audit do
  @moduledoc """
  Writes `SimpleFit.Gyms.AuditEvent` rows inside the caller's transaction
  (D-G18), so an event exists exactly when its transition commits. Internal
  to `SimpleFit.Gyms`.
  """

  alias SimpleFit.Gyms.AuditEvent
  alias SimpleFit.Repo

  @doc """
  Records one event. `attrs`: `gym_id`, `actor_user_id`, `event_type` and,
  as the event needs, `staff_membership_id`, `staff_invitation_id`,
  `from_role`, `to_role`, `reason`. Must run inside a transaction.
  """
  @spec record!(map(), DateTime.t()) :: :ok
  def record!(attrs, occurred_at) when is_map(attrs) do
    true = Repo.in_transaction?()

    %AuditEvent{} =
      AuditEvent
      |> struct!(Map.put(attrs, :occurred_at, occurred_at))
      |> Repo.insert!(log: false)

    :ok
  end
end
