defmodule SimpleFit.FirstRunTest do
  use SimpleFit.DataCase, async: true

  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Fighters
  alias SimpleFit.FirstRun
  alias SimpleFit.FirstRun.Outcome
  alias SimpleFit.Repo
  alias SimpleFitWeb.ChangesetErrors

  setup do
    {:ok, user} =
      Accounts.register_user(:google, "first-run-#{System.unique_integer([:positive])}")

    %{user: user}
  end

  defp tour(user) do
    [state] = FirstRun.list_experiences(user)
    assert state.experience == :fighter_web_tour
    state
  end

  describe "list_experiences/1" do
    test "unavailable until Fighter onboarding is complete, then pending", %{user: user} do
      assert %{status: :unavailable, recorded_at: nil} = tour(user)

      complete_account_registration!(user)
      assert %{status: :unavailable} = tour(user)

      {:ok, _} = Fighters.update_profile(user, %{"display_name" => "Alex K."})
      assert %{status: :unavailable} = tour(user)

      {:ok, _} =
        Fighters.update_profile(user, %{
          "username" => "first_run_#{System.unique_integer([:positive])}",
          "country_code" => "PL",
          "city" => "Warsaw",
          "experience_level" => "amateur",
          "stance" => "orthodox"
        })

      assert %{status: :unavailable} = tour(user)
      {:ok, _} = Fighters.complete_onboarding(user)
      assert %{status: :pending, recorded_at: nil} = tour(user)
    end

    test "reading creates nothing", %{user: user} do
      complete_fighter_onboarding!(user)
      for _ <- 1..3, do: tour(user)
      assert Repo.aggregate(Outcome, :count) == 0
    end

    test "completing onboarding records no outcome", %{user: user} do
      complete_fighter_onboarding!(user)
      {:ok, _} = Fighters.complete_onboarding(user)
      assert %{status: :pending} = tour(user)
    end
  end

  describe "record_outcome/3" do
    setup %{user: user}, do: %{user: complete_fighter_onboarding!(user)}

    for outcome <- ~w(completed dismissed) do
      test "records #{outcome} and keeps it", %{user: user} do
        outcome = unquote(outcome)
        atom = String.to_existing_atom(outcome)

        assert {:ok,
                %{experience: :fighter_web_tour, status: ^atom, recorded_at: %DateTime{} = at}} =
                 FirstRun.record_outcome(user, "fighter_web_tour", %{"outcome" => outcome})

        assert %{status: ^atom, recorded_at: ^at} = tour(user)
      end
    end

    test "the first outcome is final: repeating or sending the other one returns it", %{
      user: user
    } do
      {:ok, first} =
        FirstRun.record_outcome(user, "fighter_web_tour", %{"outcome" => "dismissed"})

      for outcome <- ~w(dismissed completed dismissed) do
        assert {:ok, ^first} =
                 FirstRun.record_outcome(user, "fighter_web_tour", %{"outcome" => outcome})
      end

      assert Repo.aggregate(Outcome, :count) == 1
      assert %{status: :dismissed} = tour(user)
    end

    test "unknown experiences are not found", %{user: user} do
      for experience <- ["coach_web_tour", "", "FIGHTER_WEB_TOUR"] do
        assert {:error, :not_found} =
                 FirstRun.record_outcome(user, experience, %{"outcome" => "completed"})
      end
    end

    test "an invalid outcome changes nothing", %{user: user} do
      for attrs <- [%{}, %{"outcome" => nil}, %{"outcome" => "skipped"}, %{"outcome" => 1}] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 FirstRun.record_outcome(user, "fighter_web_tour", attrs)

        assert %{field_codes: %{"outcome" => [code]}} = ChangesetErrors.details(changeset)
        assert code in ["required", "invalid_choice"]
      end

      assert Repo.aggregate(Outcome, :count) == 0
    end

    test "outcomes belong to their user", %{user: user} do
      {:ok, other} = Accounts.register_user(:google, "first-run-other")
      complete_fighter_onboarding!(other)

      {:ok, _} = FirstRun.record_outcome(user, "fighter_web_tour", %{"outcome" => "completed"})
      assert %{status: :pending} = tour(other)
    end
  end

  test "an unavailable experience records nothing (conflict)", %{user: user} do
    assert {:error, :conflict} =
             FirstRun.record_outcome(user, "fighter_web_tour", %{"outcome" => "completed"})

    complete_account_registration!(user)

    assert {:error, :conflict} =
             FirstRun.record_outcome(user, "fighter_web_tour", %{"outcome" => "dismissed"})

    assert Repo.aggregate(Outcome, :count) == 0
  end

  describe "database rules" do
    setup %{user: user} do
      complete_fighter_onboarding!(user)
      {:ok, _} = FirstRun.record_outcome(user, "fighter_web_tour", %{"outcome" => "completed"})
      %{outcome: Repo.one!(Outcome)}
    end

    test "an outcome is never updated", %{outcome: outcome} do
      assert_raise Postgrex.Error,
                   ~r/first_run_outcomes_final|a first-run outcome is final/,
                   fn ->
                     Repo.query!(
                       "UPDATE first_run_outcomes SET outcome = 'dismissed' WHERE id = $1",
                       [
                         Ecto.UUID.dump!(outcome.id)
                       ]
                     )
                   end
    end

    test "one outcome per user and experience", %{outcome: outcome} do
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Outcome{
          user_id: outcome.user_id,
          experience: :fighter_web_tour,
          outcome: :dismissed,
          recorded_at: DateTime.utc_now()
        })
      end
    end

    test "outcomes go with the user", %{user: user} do
      Repo.delete!(user)
      assert Repo.aggregate(Outcome, :count) == 0
    end
  end
end
