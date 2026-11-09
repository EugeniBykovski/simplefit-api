defmodule SimpleFit.SponsorApplicationHelpers do
  @moduledoc """
  SF-113 test helpers. `review!/2` moves an application into a review state
  directly in the database, standing in for the operator review that doesn't
  exist yet (a later task, through the SF-111 action framework). **Test only:**
  no applicant API and no shipped code can do this.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.User
  alias SimpleFit.Repo
  alias SimpleFit.Sponsors.{Application, Applications}

  @doc "Every answer a submission needs (string keys, as a client sends them)."
  def complete_answers(overrides \\ %{}) do
    Map.merge(
      %{
        "company_name" => "Acme Boxing Gear Sp. z o.o.",
        "website" => "https://acme.example",
        "country_code" => "PL",
        "industry" => "boxing_equipment",
        "contact_full_name" => "Ada Nowak",
        "contact_position" => "Partnerships lead",
        "contact_email" => "ada@acme.example",
        "contact_phone" => "+48123456789",
        "interests" => ["sponsored_events"],
        "market_scope" => "countries",
        "market_countries" => ["PL"],
        "market_cities" => [],
        "budget_band" => "to_be_discussed",
        "goals" => "Support amateur boxing events in Poland."
      },
      overrides
    )
  end

  @doc "Saves `answers` as a new draft (asserting success)."
  def draft!(%User{} = user, answers \\ complete_answers()) do
    {:ok, view} =
      Applications.save(user, Map.put(answers, "client_request_id", Ecto.UUID.generate()))

    view.application
  end

  @doc "A valid submit request for `application` at its current revision."
  def submit_params(%Application{} = application, overrides \\ %{}) do
    Map.merge(
      %{
        "expected_revision" => application.revision,
        "client_request_id" => Ecto.UUID.generate(),
        "declaration_accepted" => true,
        "declaration_version" => "sponsor-application-declaration-test-1",
        "declaration_language" => "en"
      },
      overrides
    )
  end

  @doc "Submits `application` (asserting success)."
  def submitted!(%User{} = user, %Application{} = application) do
    {:ok, view} = Applications.submit(user, submit_params(application))
    view.application
  end

  @doc "Test only: moves `application` to `status` as a future reviewer would."
  def review!(%Application{id: id}, status) do
    now = DateTime.utc_now()

    stamps =
      case status do
        s when s in [:approved, :rejected] -> [decided_at: now]
        _ -> []
      end

    {1, _} =
      Repo.update_all(from(a in Application, where: a.id == ^id),
        set: [status: status] ++ stamps
      )

    Repo.get!(Application, id)
  end
end
