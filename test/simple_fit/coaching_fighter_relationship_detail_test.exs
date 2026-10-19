defmodule SimpleFit.CoachingFighterRelationshipDetailTest do
  @moduledoc """
  One relationship of the fighter by id (SF-74): the same projection as the
  fighter's list, ownership through the caller's own fighter profile, the
  sharing gate not involved, and one bounded lookup instead of a list scan.
  """

  # Not async: the sharing configuration is global.
  use SimpleFit.DataCase, async: false

  import SimpleFit.CoachingHelpers

  alias SimpleFit.{Accounts, Coaches, Coaching, Fighters}
  alias SimpleFit.Coaching.Relationship

  setup do
    configure_sharing()
    :ok
  end

  defp get(user, id), do: Coaching.get_fighter_relationship(user, id)

  defp listed(user, status) do
    {:ok, %{entries: entries}} =
      Coaching.list_fighter_relationships(user, %{"status" => status})

    entries
  end

  test "an active relationship: exactly the entry listMyCoaches shows, with the live coach identity" do
    coach = coach_user!("Coach Marek")
    fighter = fighter_user!()
    relationship = activate!(coach, fighter)

    assert {:ok, entry} = get(fighter, relationship.id)
    assert [entry] == listed(fighter, "active")
    assert entry.status == :active
    assert entry.coach == %{display_name: "Coach Marek", brand_name: "Marek Boxing"}
    assert entry.coach_display_name_at_end == nil
    assert entry.ended_at == nil and entry.ended_by == nil
    assert entry.disclosure_version == version()
    assert length(entry.disclosed_fields) == 7

    {:ok, _} = Coaches.update_profile(coach, %{"display_name" => "Coach Renamed"})
    assert {:ok, %{coach: %{display_name: "Coach Renamed"}}} = get(fighter, relationship.id)
  end

  test "an ended relationship: the historical stub, never the coach's current profile" do
    coach = coach_user!("Coach Marek")
    fighter = fighter_user!()
    relationship = activate!(coach, fighter)
    :ok = Coaching.end_relationship(coach, :coach, relationship.id)
    {:ok, _} = Coaches.update_profile(coach, %{"display_name" => "Coach Renamed Later"})

    assert {:ok, entry} = get(fighter, relationship.id)
    assert [entry] == listed(fighter, "ended")
    assert entry.status == :ended
    assert entry.coach == nil
    assert entry.coach_display_name_at_end == "Coach Marek"
    assert entry.ended_by == :coach
    assert %DateTime{} = entry.ended_at
    assert entry.disclosed_fields == []
  end

  test "foreign, unknown and malformed ids are :not_found" do
    coach = coach_user!()
    fighter_a = fighter_user!()
    fighter_b = fighter_user!()
    theirs = activate!(coach, fighter_b)

    for id <- [theirs.id, Ecto.UUID.generate(), "not-a-uuid", "", nil, 42, %{"id" => theirs.id}] do
      assert get(fighter_a, id) == {:error, :not_found}
    end

    # The coach of that relationship cannot read it through the fighter side.
    assert get(coach, theirs.id) == {:error, :not_found}
  end

  test "a user without a completed fighter profile cannot read anything" do
    coach = coach_user!()
    fighter = fighter_user!()
    relationship = activate!(coach, fighter)
    no_profile = registered_user!("nofighter")

    assert get(no_profile, relationship.id) == {:error, :not_found}
  end

  test "a dual-role user reads only relationships of their own fighter profile" do
    other_coach = coach_user!("Coach Other")
    dual = fighter_user!() |> complete_coach!("Dual Coach")
    some_fighter = fighter_user!()

    as_fighter = activate!(other_coach, dual)
    as_coach = activate!(dual, some_fighter)

    assert {:ok, %{relationship_id: id}} = get(dual, as_fighter.id)
    assert id == as_fighter.id
    assert get(dual, as_coach.id) == {:error, :not_found}
  end

  test "the sharing gate does not hide the fighter's own relationships" do
    coach = coach_user!()
    fighter = fighter_user!()
    active = activate!(coach, fighter)
    ended = activate!(coach_user!("Coach B"), fighter)
    :ok = Coaching.end_relationship(fighter, :fighter, ended.id)

    set_sharing(enabled: false, disclosures: %{}, current: nil)

    assert {:ok, %{status: :active}} = get(fighter, active.id)
    assert {:ok, %{status: :ended}} = get(fighter, ended.id)
  end

  test "deleting the coach or the fighter profile makes the relationship unknown" do
    coach = coach_user!()
    fighter = fighter_user!()
    relationship = activate!(coach, fighter)

    Repo.delete_all(from(u in Accounts.User, where: u.id == ^coach.id))
    assert get(fighter, relationship.id) == {:error, :not_found}

    coach_b = coach_user!("Coach B")
    fighter_b = fighter_user!()
    rel_b = activate!(coach_b, fighter_b)
    profile = Fighters.get_profile(fighter_b)
    Repo.delete!(profile)

    assert get(fighter_b, rel_b.id) == {:error, :not_found}
    refute Repo.get(Relationship, rel_b.id)
  end

  test "a coach deleted between the relationship read and the coach read: :not_found, never half" do
    coach = coach_user!()
    fighter = fighter_user!()
    relationship = activate!(coach, fighter)
    parent = self()
    handler = "sf74-delete-#{System.unique_integer([:positive])}"

    # Right after the relationship row is read, delete the coach (and, by
    # cascade, the relationship), on the same connection, once.
    :telemetry.attach(
      handler,
      [:simple_fit, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent and metadata.source == "coach_fighter_relationships" and
             Process.get(:sf74_deleted) != true do
          Process.put(:sf74_deleted, true)
          Repo.delete_all(from(u in Accounts.User, where: u.id == ^coach.id))
        end
      end,
      nil
    )

    result = get(fighter, relationship.id)
    :telemetry.detach(handler)

    assert Process.get(:sf74_deleted) == true
    assert result == {:error, :not_found}
  end

  test "one bounded lookup: no list scan, whatever the number of relationships" do
    fighter = fighter_user!()
    relationships = for n <- 1..25, do: activate!(coach_user!("Coach #{n}"), fighter)
    target = Enum.at(relationships, 12)

    {result, queries} = count_queries(fn -> get(fighter, target.id) end)
    assert {:ok, %{relationship_id: id}} = result
    assert id == target.id
    # Fighter profile, the relationship by id, the coach's public identity.
    assert length(queries) == 3

    relationship_query = Enum.find(queries, &(&1 =~ ~s(FROM "coach_fighter_relationships")))
    assert relationship_query =~ ~s(c0."fighter_profile_id" = $1)
    assert relationship_query =~ ~s(c0."id" = $2)
    refute relationship_query =~ "LIMIT"
    refute relationship_query =~ "ORDER BY"
  end

  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler = "sf74-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:simple_fit, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {ref, metadata.query})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, collect(ref, [])}
  end

  defp collect(ref, acc) do
    receive do
      {^ref, query} -> collect(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
