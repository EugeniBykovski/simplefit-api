defmodule SimpleFit.CoachingIncomingResponsesTest do
  @moduledoc """
  Previewing, accepting and declining an invitation by id from the
  recipient's inbox (SF-73): the fail-closed switch that keeps preview and
  accept off until SF-72, verified-recipient binding (an id is never a
  credential) and convergence with the SF-57 token responses.
  """

  # Not async: the sharing configuration is global.
  use SimpleFit.DataCase, async: false

  import SimpleFit.CoachingHelpers
  import SimpleFit.EmailAuthHelpers

  alias SimpleFit.{Accounts, Coaching}
  alias SimpleFit.Coaching.{Invitation, Relationship}

  @ip "203.0.113.7"

  setup do
    configure_sharing(id_acceptance: true)
    reset_rate_limits()
    :ok
  end

  defp address, do: "by-id-#{System.unique_integer([:positive])}@example.com"

  defp invite_to!(coach, email) do
    reset_rate_limits()
    invite!(coach, email)
  end

  defp accept(user, id, version \\ version()),
    do: Coaching.accept_incoming_invitation(user, id, %{"disclosure_version" => version}, @ip)

  defp decline(user, id), do: Coaching.decline_incoming_invitation(user, id, @ip)
  defp preview(user, id), do: Coaching.preview_incoming_invitation(user, id, @ip)
  defp relationships, do: Repo.aggregate(Relationship, :count)
  defp reload(%Invitation{id: id}), do: Repo.get!(Invitation, id)

  defp registered_email_user!(email) do
    {:ok, user} = Accounts.register_user(:email, email)
    SimpleFit.AccountRegistrationHelpers.complete_account_registration!(user)
  end

  describe "fail-closed until SF-72" do
    test "the switch is off in config.exs and is not read from the environment" do
      config = Config.Reader.read!("config/config.exs", env: :prod)
      assert config[:simple_fit][SimpleFit.Coaching][:id_acceptance_enabled] == false
      refute File.read!("config/runtime.exs") =~ "id_acceptance"
      refute File.read!(".env.example") =~ ~r/ID_ACCEPTANCE/i
    end

    test "with the production default, preview and accept by id are unavailable, even for a 17-year-old" do
      set_sharing(id_acceptance: false)
      coach = inviting_coach!()
      email = address()
      {:ok, minor} = Accounts.register_user(:email, email)

      seventeen =
        Date.utc_today() |> Date.shift(year: -17) |> Date.to_iso8601()

      {:ok, _} =
        Accounts.update_account_registration(minor, %{
          "full_name" => "Young Fighter",
          "date_of_birth" => seventeen,
          "accept_terms" => true,
          "accept_privacy" => true
        })

      {:ok, %{status: :complete}} = Accounts.complete_account_registration(minor)

      {:ok, _} =
        SimpleFit.Fighters.update_profile(minor, %{
          "display_name" => "Young F.",
          "username" => "young_#{System.unique_integer([:positive])}",
          "country_code" => "PL",
          "city" => "Warsaw",
          "experience_level" => "amateur",
          "stance" => "orthodox"
        })

      {:ok, _} = SimpleFit.Fighters.complete_onboarding(minor)
      {invitation, _token} = invite_to!(coach, email)

      # No 18+ or document-language check exists yet (SF-72): the id path
      # stays closed instead of accepting.
      assert preview(minor, invitation.id) == {:error, :not_found}
      assert accept(minor, invitation.id) == {:error, :not_found}
      assert relationships() == 0
      assert reload(invitation).status == :pending
    end

    test "decline by id follows the SF-57 decline policy: available with the switch and the gate off" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      {invitation, _} = invite_to!(coach, email)
      set_sharing(enabled: false, id_acceptance: false)

      assert decline(fighter, invitation.id) == :ok
      assert reload(invitation).status == :declined
      assert relationships() == 0
    end

    test "with the gate off or no current disclosure, preview and accept are unavailable" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      {invitation, _} = invite_to!(coach, email)

      for opts <- [[enabled: false], [disclosures: %{}, current: nil]] do
        set_sharing([id_acceptance: true] ++ opts)
        assert preview(fighter, invitation.id) == {:error, :not_found}
        assert accept(fighter, invitation.id) == {:error, :not_found}
      end

      assert relationships() == 0
    end
  end

  describe "verified recipient binding" do
    test "the recipient previews and accepts; the relationship and consumption commit together" do
      coach = inviting_coach!("Coach Marek")
      email = address()
      fighter = email_fighter!(email)
      {invitation, _} = invite_to!(coach, email)

      assert {:ok, preview} = preview(fighter, invitation.id)
      assert preview.coach.display_name == "Coach Marek"
      assert preview.disclosure.version == version()

      assert {:ok, %{relationship_id: rel_id, outcome: :created}} =
               accept(fighter, invitation.id, preview.disclosure.version)

      stored = reload(invitation)
      assert stored.status == :accepted
      assert stored.accepted_disclosure_version == version()
      assert stored.relationship_id == rel_id
      assert Repo.get!(Relationship, rel_id).disclosure_version == version()
    end

    test "foreign, unknown and malformed ids are indistinguishable and change nothing" do
      coach = inviting_coach!()
      email = address()
      _owner = email_fighter!(email)
      {invitation, _} = invite_to!(coach, email)

      stranger = email_fighter!(address())
      oauth_only = fighter_user!()

      for who <- [stranger, oauth_only],
          id <- [invitation.id, Ecto.UUID.generate(), "not-a-uuid", "", nil, 42] do
        reset_rate_limits()
        assert preview(who, id) == {:error, :invitation_unavailable}
        assert accept(who, id) == {:error, :invitation_unavailable}
        assert decline(who, id) == {:error, :invitation_unavailable}
      end

      assert reload(invitation).status == :pending
      assert relationships() == 0
    end

    test "the coach who sent it cannot respond to it by id" do
      coach = inviting_coach!()
      email = address()
      {invitation, _} = invite_to!(coach, email)

      assert accept(coach, invitation.id) == {:error, :invitation_unavailable}
      assert decline(coach, invitation.id) == {:error, :invitation_unavailable}
    end

    test "an invitation to a second verified identity can be accepted" do
      coach = inviting_coach!()
      first = address()
      second = address()
      fighter = email_fighter!(first)
      {:ok, _} = Accounts.link_identity(fighter, :email, second)
      {invitation, _} = invite_to!(coach, second)

      assert {:ok, %{outcome: :created}} = accept(fighter, invitation.id)
    end
  end

  describe "prerequisites and versions (shared with the token acceptance)" do
    test "account registration, then the fighter profile, are required" do
      coach = inviting_coach!()
      email = address()
      {invitation, _} = invite_to!(coach, email)
      {:ok, user} = Accounts.register_user(:email, email)

      assert {:error, %Ecto.Changeset{errors: [account_registration: _]}} =
               accept(user, invitation.id)

      user = SimpleFit.AccountRegistrationHelpers.complete_account_registration!(user)

      assert {:error, %Ecto.Changeset{errors: [fighter_profile: _]}} =
               accept(user, invitation.id)

      assert {:error, %Ecto.Changeset{errors: [fighter_profile: _]}} =
               decline(user, invitation.id)

      assert reload(invitation).status == :pending
      assert relationships() == 0
    end

    test "the disclosure version must be echoed exactly" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      {invitation, _} = invite_to!(coach, email)

      assert accept(fighter, invitation.id, "old-version") ==
               {:error, {:conflict, %{disclosure_version: "stale"}}}

      assert {:error, %Ecto.Changeset{}} =
               Coaching.accept_incoming_invitation(fighter, invitation.id, %{}, @ip)

      assert reload(invitation).status == :pending
      assert relationships() == 0
    end

    test "expired, cancelled, declined and consumed invitations are unavailable" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)

      {expired, _} = invite_to!(coach, email)
      past = DateTime.add(DateTime.utc_now(), -1)
      Repo.update_all(from(i in Invitation, where: i.id == ^expired.id), set: [expires_at: past])
      assert accept(fighter, expired.id) == {:error, :invitation_unavailable}
      assert preview(fighter, expired.id) == {:error, :invitation_unavailable}

      coach_b = inviting_coach!("Coach B")
      {cancelled, _} = invite_to!(coach_b, email)
      :ok = Coaching.cancel_invitation(coach_b, cancelled.id)
      assert accept(fighter, cancelled.id) == {:error, :invitation_unavailable}

      coach_c = inviting_coach!("Coach C")
      {declined, _} = invite_to!(coach_c, email)
      :ok = decline(fighter, declined.id)
      assert accept(fighter, declined.id) == {:error, :invitation_unavailable}
      assert decline(fighter, declined.id) == {:error, :invitation_unavailable}

      coach_d = inviting_coach!("Coach D")
      {used, _} = invite_to!(coach_d, email)
      {:ok, _} = accept(fighter, used.id)
      assert accept(fighter, used.id) == {:error, :invitation_unavailable}

      assert relationships() == 1
    end
  end

  describe "convergence with the token responses" do
    test "accepted by token, then by id (and the reverse): one relationship, the second is unavailable" do
      email = address()
      fighter = email_fighter!(email)

      coach = inviting_coach!()
      {by_token, token} = invite_to!(coach, email)

      {:ok, _} =
        Coaching.accept_invitation(
          fighter,
          %{"token" => token, "disclosure_version" => version()},
          @ip
        )

      assert accept(fighter, by_token.id) == {:error, :invitation_unavailable}

      coach_b = inviting_coach!("Coach B")
      {by_id, token_b} = invite_to!(coach_b, email)
      {:ok, _} = accept(fighter, by_id.id)

      assert Coaching.accept_invitation(
               fighter,
               %{"token" => token_b, "disclosure_version" => version()},
               @ip
             ) == {:error, :invitation_unavailable}

      assert relationships() == 2
    end

    test "an id survives a resend; the old token does not" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      {invitation, old_token} = invite_to!(coach, email)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [last_sent_at: DateTime.add(DateTime.utc_now(), -120)]
      )

      {:ok, _} = Coaching.resend_invitation(coach, invitation.id, @ip)

      assert Coaching.accept_invitation(
               fighter,
               %{"token" => old_token, "disclosure_version" => version()},
               @ip
             ) == {:error, :invitation_unavailable}

      assert {:ok, %{outcome: :created}} = accept(fighter, invitation.id)
    end

    test "an already connected pair keeps its relationship and its accepted disclosure" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      relationship = activate!(coach, fighter)
      {invitation, _} = invite_to!(coach, email)

      assert {:ok, %{relationship_id: id, outcome: :already_connected}} =
               accept(fighter, invitation.id)

      assert id == relationship.id
      assert relationships() == 1
      assert reload(invitation).relationship_id == relationship.id
    end

    test "after an ended relationship a new invitation accepted by id creates a new one" do
      coach = inviting_coach!()
      email = address()
      fighter = email_fighter!(email)
      first = activate!(coach, fighter)
      :ok = end_relationship!(fighter, first)
      {invitation, _} = invite_to!(coach, email)

      assert {:ok, %{relationship_id: id, outcome: :created}} = accept(fighter, invitation.id)
      refute id == first.id
    end
  end

  defp end_relationship!(fighter, relationship) do
    case Coaching.end_relationship(fighter, :fighter, relationship.id) do
      {:ok, _} -> :ok
      :ok -> :ok
    end
  end
end
