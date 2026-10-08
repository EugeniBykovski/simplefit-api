defmodule SimpleFit.Accounts.RegistrationTest do
  use SimpleFit.DataCase, async: false

  import ExUnit.CaptureLog

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{AccountConsent, AccountProfile}
  alias SimpleFit.Fighters
  alias SimpleFit.Repo
  alias SimpleFitWeb.ChangesetErrors

  setup do
    {:ok, user} = Accounts.register_user(:google, "account-#{System.unique_integer([:positive])}")
    %{user: user}
  end

  defp years_ago(years), do: Date.shift(Date.utc_today(), year: -years)

  defp complete_attrs,
    do: %{
      "full_name" => "Alex Kowalski",
      "date_of_birth" => Date.to_iso8601(years_ago(30)),
      "accept_terms" => true,
      "accept_privacy" => true
    }

  defp field_codes({:error, changeset}), do: ChangesetErrors.details(changeset).field_codes

  defp consents(user),
    do: Repo.all(from(c in AccountConsent, where: c.user_id == ^user.id, order_by: c.recorded_at))

  describe "a user alone" do
    test "is not_started with every requirement missing, and nothing is created", %{user: user} do
      registration = Accounts.get_account_registration(user)

      assert registration.status == :not_started
      assert registration.profile == nil
      assert registration.missing_requirements == [:full_name, :date_of_birth, :terms, :privacy]
      refute Accounts.registration_complete?(user)
      assert Repo.aggregate(AccountProfile, :count) == 0
      assert Repo.aggregate(AccountConsent, :count) == 0
    end

    test "completing registration infers no role or role profile", %{user: user} do
      {:ok, _} = Accounts.update_account_registration(user, complete_attrs())
      {:ok, _} = Accounts.complete_account_registration(user)

      assert Fighters.get_profile(user) == nil

      assert Map.keys(Repo.get!(Accounts.User, user.id) |> Map.from_struct()) |> Enum.sort() ==
               [:__meta__, :id, :identities, :inserted_at, :updated_at]
    end
  end

  describe "saving progress" do
    test "a save with nothing to persist creates nothing", %{user: user} do
      for attrs <- [
            %{},
            %{"unknown" => "x"},
            %{"full_name" => nil},
            %{"full_name" => "  "},
            %{"product_news" => false}
          ] do
        assert {:ok, %{status: :not_started}} = Accounts.update_account_registration(user, attrs)
      end

      assert Repo.aggregate(AccountProfile, :count) == 0
      assert consents(user) == []
    end

    test "partial saves create one in-progress profile and keep earlier fields", %{user: user} do
      {:ok, first} =
        Accounts.update_account_registration(user, %{"full_name" => "  Alex Kowalski "})

      assert first.status == :in_progress
      assert first.profile.full_name == "Alex Kowalski"

      {:ok, second} =
        Accounts.update_account_registration(user, %{
          "date_of_birth" => Date.to_iso8601(years_ago(20))
        })

      assert second.profile.id == first.profile.id
      assert second.profile.full_name == "Alex Kowalski"
      assert second.missing_requirements == [:terms, :privacy]
    end

    test "a consent decision alone starts registration", %{user: user} do
      assert {:ok, %{status: :in_progress} = registration} =
               Accounts.update_account_registration(user, %{"accept_terms" => true})

      assert registration.missing_requirements == [:full_name, :date_of_birth, :privacy]
    end

    test "an invalid save changes and creates nothing", %{user: user} do
      assert {:error, _} =
               Accounts.update_account_registration(user, %{
                 "full_name" => "Alex Kowalski",
                 "accept_terms" => true,
                 "date_of_birth" => "not-a-date"
               })

      assert Repo.aggregate(AccountProfile, :count) == 0
      assert consents(user) == []
    end

    test "full name is trimmed and bounded", %{user: user} do
      assert field_codes(
               Accounts.update_account_registration(user, %{
                 "full_name" => String.duplicate("a", 201)
               })
             ) ==
               %{"full_name" => ["too_long"]}
    end
  end

  describe "date of birth" do
    test "must be a real calendar date", %{user: user} do
      for value <- ["2001-02-30", "2001-13-01", "17/05/2000", 20_000_517] do
        assert %{"date_of_birth" => ["invalid_type"]} =
                 field_codes(
                   Accounts.update_account_registration(user, %{"date_of_birth" => value})
                 )
      end
    end

    test "cannot be in the future", %{user: user} do
      tomorrow = Date.add(Date.utc_today(), 1)

      assert field_codes(
               Accounts.update_account_registration(user, %{
                 "date_of_birth" => Date.to_iso8601(tomorrow)
               })
             ) ==
               %{"date_of_birth" => ["out_of_range"]}
    end

    test "exactly 16 years ago today is accepted; one day less is too_young", %{user: user} do
      sixteen = years_ago(16)

      assert field_codes(
               Accounts.update_account_registration(user, %{
                 "date_of_birth" => Date.to_iso8601(Date.add(sixteen, 1))
               })
             ) == %{"date_of_birth" => ["too_young"]}

      assert {:ok, registration} =
               Accounts.update_account_registration(user, %{
                 "date_of_birth" => Date.to_iso8601(sixteen)
               })

      assert registration.profile.date_of_birth == sixteen
    end

    test "age is counted by calendar date" do
      assert AccountProfile.age(~D[2010-05-17], ~D[2026-05-16]) == 15
      assert AccountProfile.age(~D[2010-05-17], ~D[2026-05-17]) == 16
      assert AccountProfile.age(~D[2008-02-29], ~D[2024-02-28]) == 15
      assert AccountProfile.age(~D[2008-02-29], ~D[2024-02-29]) == 16
      assert AccountProfile.age(~D[2008-02-29], ~D[2025-02-28]) == 16
      assert AccountProfile.age(~D[2009-02-28], ~D[2025-02-28]) == 16
    end
  end

  describe "required consents" do
    test "record the current Terms and Privacy versions once", %{user: user} do
      {:ok, registration} =
        Accounts.update_account_registration(user, %{
          "accept_terms" => true,
          "accept_privacy" => true
        })

      assert %{
               accepted: true,
               accepted_version: "terms-v1",
               current_version: "terms-v1",
               current: true
             } =
               registration.consents.terms

      assert %{accepted_version: "privacy-v1", current: true} = registration.consents.privacy

      {:ok, _} = Accounts.update_account_registration(user, %{"accept_terms" => true})

      assert [{:terms, "terms-v1", :accepted}, {:privacy, "privacy-v1", :accepted}] ==
               user
               |> consents()
               |> Enum.map(&{&1.kind, &1.document_version, &1.decision})
               |> Enum.sort_by(&(elem(&1, 0) != :terms))
    end

    test "cannot be withdrawn", %{user: user} do
      {:ok, _} = Accounts.update_account_registration(user, %{"accept_terms" => true})

      assert field_codes(Accounts.update_account_registration(user, %{"accept_terms" => false})) ==
               %{"accept_terms" => ["must_be_accepted"]}

      assert field_codes(Accounts.update_account_registration(user, %{"accept_privacy" => nil})) ==
               %{"accept_privacy" => ["must_be_accepted"]}

      assert Accounts.get_account_registration(user).consents.terms.current
    end

    test "the database keeps the history append-only and required consents accepted", %{
      user: user
    } do
      {:ok, _} = Accounts.update_account_registration(user, %{"accept_terms" => true})

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(c in AccountConsent, where: c.user_id == ^user.id),
          set: [decision: :withdrawn]
        )
      end

      assert_raise Postgrex.Error, ~r/required_consent_shape/, fn ->
        Repo.insert_all(AccountConsent, [
          %{
            id: Ecto.UUID.generate(),
            user_id: user.id,
            kind: :terms,
            document_version: "terms-v1",
            decision: :withdrawn,
            recorded_at: DateTime.utc_now()
          }
        ])
      end
    end
  end

  describe "product news" do
    test "is optional, withdrawable and keeps its history", %{user: user} do
      {:ok, r1} =
        Accounts.update_account_registration(user, %{
          "full_name" => "Alex",
          "product_news" => true
        })

      assert r1.consents.product_news.subscribed

      {:ok, r2} = Accounts.update_account_registration(user, %{"product_news" => false})
      refute r2.consents.product_news.subscribed

      {:ok, r3} = Accounts.update_account_registration(user, %{"product_news" => true})
      assert r3.consents.product_news.subscribed
      {:ok, _} = Accounts.update_account_registration(user, %{"product_news" => true})

      assert user
             |> consents()
             |> Enum.filter(&(&1.kind == :product_news))
             |> Enum.map(&{&1.decision, &1.document_version}) ==
               [{:accepted, nil}, {:withdrawn, nil}, {:accepted, nil}]

      refute :product_news in r3.missing_requirements
    end

    test "never blocks completion", %{user: user} do
      {:ok, _} =
        Accounts.update_account_registration(
          user,
          Map.put(complete_attrs(), "product_news", false)
        )

      assert {:ok, %{status: :complete}} = Accounts.complete_account_registration(user)
    end

    test "rejects null", %{user: user} do
      assert field_codes(Accounts.update_account_registration(user, %{"product_news" => nil})) ==
               %{"product_news" => ["required"]}
    end
  end

  describe "completion" do
    test "without a profile lists every requirement and creates nothing", %{user: user} do
      assert field_codes(Accounts.complete_account_registration(user)) == %{
               "full_name" => ["required"],
               "date_of_birth" => ["required"],
               "terms" => ["required"],
               "privacy" => ["required"]
             }

      assert Repo.aggregate(AccountProfile, :count) == 0
    end

    test "is blocked per missing requirement and changes nothing", %{user: user} do
      {:ok, _} =
        Accounts.update_account_registration(user, Map.delete(complete_attrs(), "accept_privacy"))

      assert field_codes(Accounts.complete_account_registration(user)) == %{
               "privacy" => ["required"]
             }

      assert Accounts.get_account_registration(user).status == :in_progress
    end

    test "succeeds, is persisted and is idempotent", %{user: user} do
      {:ok, _} = Accounts.update_account_registration(user, complete_attrs())

      assert {:ok, %{status: :complete, missing_requirements: []} = first} =
               Accounts.complete_account_registration(user)

      assert Accounts.registration_complete?(user)
      {:ok, again} = Accounts.complete_account_registration(user)
      assert again.profile.registration_completed_at == first.profile.registration_completed_at
      assert Accounts.get_account_registration(user).status == :complete
    end

    test "concurrent completions converge on one completion time", %{user: user} do
      {:ok, _} = Accounts.update_account_registration(user, complete_attrs())

      results =
        Task.await_many(
          for _ <- 1..2, do: Task.async(fn -> Accounts.complete_account_registration(user) end)
        )

      assert [{:ok, a}, {:ok, b}] = results
      assert a.profile.registration_completed_at == b.profile.registration_completed_at
    end
  end

  describe "a completed registration" do
    setup %{user: user} do
      {:ok, _} = Accounts.update_account_registration(user, complete_attrs())
      {:ok, _} = Accounts.complete_account_registration(user)
      :ok
    end

    test "keeps the full name editable but required", %{user: user} do
      {:ok, registration} =
        Accounts.update_account_registration(user, %{"full_name" => "Alex K. Kowalski"})

      assert registration.profile.full_name == "Alex K. Kowalski"

      assert field_codes(Accounts.update_account_registration(user, %{"full_name" => nil})) ==
               %{"full_name" => ["required"]}
    end

    test "cannot change the date of birth, also at the database", %{user: user} do
      assert field_codes(
               Accounts.update_account_registration(user, %{
                 "date_of_birth" => Date.to_iso8601(years_ago(25))
               })
             ) == %{"date_of_birth" => ["immutable"]}

      profile = Accounts.get_account_registration(user).profile

      assert_raise Ecto.ConstraintError, ~r/account_profiles_completed_immutable/, fn ->
        profile |> Ecto.Changeset.change(date_of_birth: years_ago(40)) |> Repo.update()
      end
    end

    test "allows product news changes", %{user: user} do
      assert {:ok, %{consents: %{product_news: %{subscribed: true}}}} =
               Accounts.update_account_registration(user, %{"product_news" => true})
    end
  end

  test "concurrent first saves converge on one profile", %{user: user} do
    results =
      Task.await_many(
        for name <- ["Alex", "Alexander"],
            do:
              Task.async(fn ->
                Accounts.update_account_registration(user, %{"full_name" => name})
              end)
      )

    assert [{:ok, a}, {:ok, b}] = results
    assert a.profile.id == b.profile.id
    assert Repo.aggregate(AccountProfile, :count) == 1
  end

  test "deleting the user deletes the profile and the consent history", %{user: user} do
    {:ok, _} =
      Accounts.update_account_registration(user, Map.put(complete_attrs(), "product_news", true))

    Repo.delete!(user)

    assert Repo.aggregate(AccountProfile, :count) == 0
    assert Repo.aggregate(AccountConsent, :count) == 0
  end

  test "personal data is redacted from inspect output and never logged", %{user: user} do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :debug], fn ->
        {:ok, registration} = Accounts.update_account_registration(user, complete_attrs())
        send(self(), {:inspected, inspect(registration.profile)})
        {:ok, _} = Accounts.complete_account_registration(user)
        _ = Accounts.get_account_registration(user)
      end)

    assert_received {:inspected, inspected}
    dob = Date.to_iso8601(years_ago(30))

    for value <- ["Alex Kowalski", dob] do
      refute log =~ value
      refute inspected =~ value
    end
  end
end
