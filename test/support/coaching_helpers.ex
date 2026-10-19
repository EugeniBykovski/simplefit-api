defmodule SimpleFit.CoachingHelpers do
  @moduledoc """
  Test helpers for Coach–Fighter relationships (ADR 0021): users with
  completed coach / fighter profiles, a controlled sharing configuration and
  activation through the trusted boundary (`SimpleFit.Coaching.Activation`),
  the way the future invitation acceptance will call it.

  The sharing configuration is global application state: tests that change
  it are not async and restore it with `configure_sharing/1`'s `on_exit`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import SimpleFit.AccountRegistrationHelpers
  import SimpleFit.FighterOnboardingHelpers

  alias SimpleFit.Accounts
  alias SimpleFit.Accounts.User
  alias SimpleFit.Coaches
  alias SimpleFit.Coaching.Activation

  @version "fighter-coach-disclosure-test-1"
  @data_rules "coach-data-rules-test-1"

  @doc "The coach data-rules version tests configure (a test identifier)."
  def data_rules_version, do: @data_rules

  @doc "The disclosure version tests configure (a test identifier, never a legal text)."
  def version, do: @version

  @doc """
  Sets the Coach–Fighter sharing gate and disclosure versions for this test
  (defaults: enabled, `version/0` with the `basic_profile` scope, the
  test-only versions of `test/support/legal`) and restores the previous
  configuration afterwards.
  """
  def configure_sharing(opts \\ []) do
    previous = Application.get_env(:simple_fit, SimpleFit.Coaching)
    on_exit(fn -> Application.put_env(:simple_fit, SimpleFit.Coaching, previous) end)
    set_sharing(opts)
  end

  @doc "Changes the sharing configuration within a test (already restored by `configure_sharing/1`)."
  def set_sharing(opts) do
    disclosures = Keyword.get(opts, :disclosures, %{@version => :basic_profile})

    Application.put_env(:simple_fit, SimpleFit.Coaching,
      access_enabled: Keyword.get(opts, :enabled, true),
      disclosures: disclosures,
      current_disclosure: Keyword.get(opts, :current, @version),
      data_rules_version: Keyword.get(opts, :data_rules, @data_rules)
    )
  end

  @doc "A new user (Google identity) with completed account registration."
  def registered_user!(prefix \\ "coaching") do
    {:ok, user} =
      Accounts.register_user(:google, "#{prefix}-#{System.unique_integer([:positive])}")

    complete_account_registration!(user)
  end

  @doc "Completes Coach onboarding for `user` (account registration must be complete)."
  def complete_coach!(%User{} = user, name \\ "Coach Marek") do
    {:ok, _} =
      Coaches.update_profile(user, %{
        "display_name" => name,
        "brand_name" => "Marek Boxing",
        "country_code" => "PL",
        "city" => "Warsaw",
        "coaching_formats" => ["personal_training"]
      })

    {:ok, _} = Coaches.complete_onboarding(user)
    user
  end

  @doc "A new user with a completed coach profile."
  def coach_user!(name \\ "Coach Marek"), do: registered_user!("coach") |> complete_coach!(name)

  @doc "A new user with a completed fighter profile."
  def fighter_user! do
    {:ok, user} = Accounts.register_user(:google, "fighter-#{System.unique_integer([:positive])}")
    complete_fighter_onboarding!(user)
  end

  @doc "A new user signed up with the email identity `address` and a completed fighter profile."
  def email_fighter!(address) do
    {:ok, user} = Accounts.register_user(:email, address)
    complete_fighter_onboarding!(user)
  end

  @doc "A coach who acknowledged the configured data rules and can invite."
  def inviting_coach!(name \\ "Coach Marek") do
    coach = coach_user!(name)

    {:ok, _} =
      SimpleFit.Coaching.acknowledge_coach_data_rules(coach, %{
        "document_version" => @data_rules,
        "document_language" => "en"
      })

    coach
  end

  @doc """
  Invites `address` as `coach` and returns the invitation with the token
  from the queued E08 (the way a recipient receives it).
  """
  def invite!(coach, address, attrs \\ %{}) do
    {:ok, invitation, :created} =
      SimpleFit.Coaching.invite(coach, Map.put(attrs, "email", address), "203.0.113.7")

    {invitation, last_token_to(address)}
  end

  @doc "The invitation token of the latest E08 queued to `address`."
  def last_token_to(address) do
    %{text: text} = SimpleFit.EmailAuthHelpers.last_email_to(address)
    [_, token] = Regex.run(~r"/invite/coach#token=(sfi_[A-Za-z0-9_-]{43})", text)
    token
  end

  @doc "Activates the relationship `fighter` accepts from `coach` (sharing must be configured)."
  def activate!(%User{} = coach, %User{} = fighter, version \\ @version) do
    {:ok, relationship, _outcome} =
      Activation.activate(Coaches.get_profile(coach).id, fighter, version)

    relationship
  end
end
