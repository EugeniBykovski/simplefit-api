defmodule SimpleFit.TrainingHelpers do
  @moduledoc """
  Test helpers for training sessions (ADR 0023): valid create attributes for
  a relationship, and sessions assigned through the domain.
  """

  alias SimpleFit.Training

  @doc "An RFC 3339 UTC instant `days` from now, whole seconds."
  def in_days(days) do
    DateTime.utc_now()
    |> DateTime.add(days * 86_400, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc "Valid create attributes (string keys) for `relationship_id`, with `overrides`."
  def session_attrs(relationship_id, overrides \\ %{}) do
    Map.merge(
      %{
        "relationship_id" => relationship_id,
        "client_request_id" => Ecto.UUID.generate(),
        "title" => "Technical boxing",
        "training_type" => "technical",
        "starts_at" => in_days(2),
        "time_zone" => "Europe/Warsaw",
        "duration_minutes" => 60,
        "notes" => "Jab work"
      },
      overrides
    )
  end

  @doc "Assigns a session as `coach` under `relationship_id` and returns its coach view."
  def assign!(coach, relationship_id, overrides \\ %{}) do
    {:ok, view, :created} =
      Training.create_session(coach, session_attrs(relationship_id, overrides))

    view
  end
end
