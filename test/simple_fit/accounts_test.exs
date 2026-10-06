defmodule SimpleFit.AccountsTest do
  # Not async: the concurrency tests share the sandbox connection with tasks.
  use SimpleFit.DataCase, async: false

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.{Identity, User}

  @google_sub "109876543210987654321"
  @apple_sub "001234.5f2a7c0e9b8d4e1f.0912"

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp field_codes(changeset), do: SimpleFitWeb.ChangesetErrors.details(changeset).field_codes

  describe "register_user/2" do
    test "creates one user with its first identity" do
      assert {:ok, %User{id: user_id, identities: [identity]}} =
               Accounts.register_user(:email, "fighter@example.com")

      assert %Identity{
               user_id: ^user_id,
               provider: :email,
               provider_subject: "fighter@example.com"
             } =
               identity

      assert count(User) == 1
      assert count(Identity) == 1
    end

    test "stores email identities in canonical form" do
      assert {:ok, %User{identities: [identity]}} =
               Accounts.register_user("email", " Fighter@Example.COM ")

      assert identity.provider_subject == "fighter@example.com"
    end

    test "stores Google and Apple subjects exactly as issued" do
      assert {:ok, %User{identities: [google]}} = Accounts.register_user(:google, @google_sub)
      assert google.provider_subject == @google_sub

      assert {:ok, %User{identities: [apple]}} = Accounts.register_user(:apple, "AbC.123.xYz")
      assert apple.provider_subject == "AbC.123.xYz"
    end

    test "is a conflict when the identity already exists, and creates nothing" do
      {:ok, _user} = Accounts.register_user(:email, "taken@example.com")

      assert Accounts.register_user(:email, "Taken@Example.com ") == {:error, :conflict}
      assert count(User) == 1
      assert count(Identity) == 1
    end

    test "rejects an unsupported provider at the domain boundary" do
      assert {:error, %Ecto.Changeset{} = changeset} = Accounts.register_user(:github, "12345")
      assert %{"provider" => ["invalid_choice"]} = field_codes(changeset)
      assert count(User) == 0
    end

    test "rejects invalid subjects" do
      assert {:error, changeset} = Accounts.register_user(:email, "not-an-email")
      assert %{"provider_subject" => ["invalid_format"]} = field_codes(changeset)

      assert {:error, changeset} = Accounts.register_user(:google, "has space")
      assert %{"provider_subject" => ["invalid_format"]} = field_codes(changeset)

      assert {:error, changeset} = Accounts.register_user(:apple, String.duplicate("x", 256))
      assert %{"provider_subject" => ["too_long"]} = field_codes(changeset)

      assert {:error, changeset} = Accounts.register_user(:google, "   ")
      assert %{"provider_subject" => ["required"]} = field_codes(changeset)

      assert count(User) == 0
    end
  end

  describe "get_identity/2 and resolve_user/2" do
    setup do
      {:ok, user} = Accounts.register_user(:email, "boxer@example.com")
      %{user: user}
    end

    test "an existing identity resolves its user", %{user: user} do
      assert {:ok, %Identity{user_id: user_id}} =
               Accounts.get_identity(:email, "boxer@example.com")

      assert user_id == user.id

      assert {:ok, %User{id: resolved_id}} = Accounts.resolve_user(:email, "boxer@example.com")
      assert resolved_id == user.id
    end

    test "email lookups use the canonical form", %{user: user} do
      assert {:ok, %User{id: id}} = Accounts.resolve_user("email", "  BOXER@example.com")
      assert id == user.id
    end

    test "an unknown identity is not found" do
      assert Accounts.get_identity(:email, "nobody@example.com") == {:error, :not_found}
      assert Accounts.resolve_user(:google, @google_sub) == {:error, :not_found}
    end

    test "the subject is scoped by provider" do
      assert Accounts.resolve_user(:google, "boxer@example.com") == {:error, :not_found}
    end

    test "invalid input is a validation error, not a lookup" do
      assert {:error, %Ecto.Changeset{}} = Accounts.get_identity(:myspace, "x")
      assert {:error, %Ecto.Changeset{}} = Accounts.resolve_user(:email, "nope")
    end
  end

  describe "link_identity/3" do
    setup do
      {:ok, user} = Accounts.register_user(:email, "owner@example.com")
      %{user: user}
    end

    test "attaches a new identity to the explicitly selected user", %{user: user} do
      assert {:ok, %Identity{user_id: user_id, provider: :google}} =
               Accounts.link_identity(user, :google, @google_sub)

      assert user_id == user.id
      assert {:ok, %User{id: ^user_id}} = Accounts.resolve_user(:google, @google_sub)
    end

    test "one user can own email, Google and Apple identities at once", %{user: user} do
      {:ok, _} = Accounts.link_identity(user, :google, @google_sub)
      {:ok, _} = Accounts.link_identity(user, :apple, @apple_sub)

      identities = Repo.preload(user, :identities, force: true).identities
      assert identities |> Enum.map(& &1.provider) |> Enum.sort() == [:apple, :email, :google]
      assert Enum.all?(identities, &(&1.user_id == user.id))
      assert count(User) == 1
    end

    test "is idempotent for an identity the user already owns", %{user: user} do
      {:ok, first} = Accounts.link_identity(user, :google, @google_sub)
      assert {:ok, again} = Accounts.link_identity(user, :google, @google_sub)
      assert again.id == first.id

      assert {:ok, email} = Accounts.link_identity(user, :email, " OWNER@example.com")
      assert email.provider_subject == "owner@example.com"
      assert count(Identity) == 2
    end

    test "an identity owned by another user is a conflict and is not moved", %{user: user} do
      {:ok, other} = Accounts.register_user(:google, @google_sub)

      assert Accounts.link_identity(user, :google, @google_sub) == {:error, :conflict}
      assert Accounts.link_identity(user, :email, "Owner@Example.com") == {:ok, owned_by(user)}
      assert {:ok, %User{id: owner_id}} = Accounts.resolve_user(:google, @google_sub)
      assert owner_id == other.id
    end

    test "a matching provider email never links or merges accounts", %{user: user} do
      # Google reports owner@example.com for a new Google account. SF-19 has no
      # email-based linking: signing up with that Google subject is a separate
      # user, and the email user is untouched.
      assert Accounts.resolve_user(:google, @google_sub) == {:error, :not_found}
      {:ok, google_user} = Accounts.register_user(:google, @google_sub)

      refute google_user.id == user.id
      assert {:ok, %User{id: email_owner}} = Accounts.resolve_user(:email, "owner@example.com")
      assert email_owner == user.id
      assert count(User) == 2
    end

    test "a deleted user is not found", %{user: user} do
      Repo.delete!(user)
      assert Accounts.link_identity(user, :google, @google_sub) == {:error, :not_found}
      assert count(Identity) == 0
    end

    test "rejects an unsupported provider", %{user: user} do
      assert {:error, %Ecto.Changeset{}} = Accounts.link_identity(user, "microsoft", "abc")
      assert count(Identity) == 1
    end

    defp owned_by(user) do
      {:ok, identity} = Accounts.get_identity(:email, "owner@example.com")
      assert identity.user_id == user.id
      identity
    end
  end

  describe "database constraints (authoritative even without the domain)" do
    setup do
      {:ok, user} = Accounts.register_user(:email, "db@example.com")
      %{user: user}
    end

    defp raw_insert(user_id, provider, subject) do
      Repo.query(
        """
        INSERT INTO identities (id, user_id, provider, provider_subject, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, now(), now())
        """,
        [Ecto.UUID.bingenerate(), Ecto.UUID.dump!(user_id), provider, subject]
      )
    end

    defp constraint_of({:error, %Postgrex.Error{postgres: %{constraint: name}}}), do: name

    test "(provider, provider_subject) is unique", %{user: user} do
      assert constraint_of(raw_insert(user.id, "email", "db@example.com")) ==
               "identities_provider_provider_subject_index"
    end

    test "the same subject under two providers is allowed", %{user: user} do
      assert {:ok, _} = raw_insert(user.id, "google", "shared-subject-1")
      assert {:ok, _} = raw_insert(user.id, "apple", "shared-subject-1")
    end

    test "email subjects must be canonical", %{user: user} do
      assert constraint_of(raw_insert(user.id, "email", "Upper@Example.com")) ==
               "email_subject_canonical"

      assert constraint_of(raw_insert(user.id, "email", "no-at-sign")) ==
               "email_subject_canonical"

      # The same rule does not apply to opaque provider subjects.
      assert {:ok, _} = raw_insert(user.id, "google", "MixedCaseSubject")
    end

    test "subjects are printable ASCII up to 255 characters", %{user: user} do
      assert constraint_of(raw_insert(user.id, "google", "with space")) ==
               "provider_subject_format"

      assert constraint_of(raw_insert(user.id, "google", "")) == "provider_subject_format"

      assert constraint_of(raw_insert(user.id, "google", String.duplicate("a", 256))) ==
               "provider_subject_format"
    end

    test "providers are lowercase identifiers; new ones need no migration", %{user: user} do
      assert constraint_of(raw_insert(user.id, "Google", "x1")) == "provider_format"
      assert constraint_of(raw_insert(user.id, "", "x1")) == "provider_format"
      assert {:ok, _} = raw_insert(user.id, "future_provider", "x1")
    end

    test "an identity cannot exist without its user" do
      assert constraint_of(raw_insert(Ecto.UUID.generate(), "google", "orphan")) ==
               "identities_user_id_fkey"
    end

    test "deleting a user deletes its identities", %{user: user} do
      {:ok, _} = Accounts.link_identity(user, :google, @google_sub)
      assert count(Identity) == 2

      Repo.delete!(user)
      assert count(Identity) == 0
    end
  end

  describe "transactions" do
    test "a failed first identity rolls back the new user" do
      {:ok, _} = Accounts.register_user(:apple, @apple_sub)
      users_before = count(User)

      # The user row is inserted first; the identity insert then hits the
      # unique index and the whole transaction is rolled back.
      assert Accounts.register_user(:apple, @apple_sub) == {:error, :conflict}
      assert count(User) == users_before

      assert Repo.all(from u in User, left_join: i in assoc(u, :identities), where: is_nil(i.id)) ==
               []
    end
  end

  describe "concurrency" do
    test "concurrent registrations of one identity create exactly one user" do
      results =
        1..8
        |> Task.async_stream(fn _ -> Accounts.register_user(:email, "Race@Example.com") end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :conflict})) == 7
      assert count(User) == 1
      assert count(Identity) == 1
    end

    test "concurrent links of one identity resolve deterministically" do
      {:ok, alice} = Accounts.register_user(:email, "alice@example.com")
      {:ok, bob} = Accounts.register_user(:email, "bob@example.com")

      results =
        [alice, bob, alice, bob, alice, bob]
        |> Task.async_stream(&{&1.id, Accounts.link_identity(&1, :google, @google_sub)},
          max_concurrency: 6
        )
        |> Enum.map(fn {:ok, result} -> result end)

      {:ok, %Identity{user_id: winner}} = Accounts.get_identity(:google, @google_sub)

      for {user_id, result} <- results do
        if user_id == winner do
          assert {:ok, %Identity{user_id: ^winner}} = result
        else
          assert result == {:error, :conflict}
        end
      end

      assert Repo.aggregate(from(i in Identity, where: i.provider == :google), :count) == 1
    end
  end

  describe "privacy" do
    test "users and identities carry no credentials or role fields" do
      assert User.__schema__(:fields) == [:id, :inserted_at, :updated_at]

      assert Identity.__schema__(:fields) ==
               [:id, :user_id, :provider, :provider_subject, :inserted_at, :updated_at]
    end

    test "provider subjects are redacted from inspect output" do
      {:ok, %User{identities: [identity]}} = Accounts.register_user(:email, "secret@example.com")

      refute inspect(identity) =~ "secret@example.com"

      {:error, changeset} = Accounts.register_user(:email, "bad address@example.com")
      refute inspect(changeset) =~ "bad address"
    end

    test "conflicts reveal nothing about the owner" do
      {:ok, _} = Accounts.register_user(:google, @google_sub)
      {:ok, other} = Accounts.register_user(:email, "other@example.com")

      assert Accounts.link_identity(other, :google, @google_sub) == {:error, :conflict}
      assert Accounts.register_user(:google, @google_sub) == {:error, :conflict}
    end
  end

  describe "normalize_email/1" do
    test "exposes the canonical email policy" do
      assert Accounts.normalize_email(" User@Example.com ") == {:ok, "user@example.com"}
      assert Accounts.normalize_email("user@example.com") == {:ok, "user@example.com"}
      assert Accounts.normalize_email("nope") == :error
    end
  end
end
