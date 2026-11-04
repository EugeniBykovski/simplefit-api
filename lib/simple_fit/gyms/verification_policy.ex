defmodule SimpleFit.Gyms.VerificationPolicy do
  @moduledoc """
  The business-verification requirements (SF-103; ADR 0026 amendment
  SF-103), versioned in code so every change is reviewed. An application
  records the version it was created under.

  `sf103-generic-1` is SimpleFit's own minimum, the same for every country:
  the business's legal name, its registration country and at least one
  uploaded document. The registration number, registered address and
  website are optional details the reviewer may ask for. **No
  jurisdiction-specific requirement is approved** (Polish KRS/NIP/REGON, EU
  KYB, or any other): a country gains extra required fields only through
  reviewed configuration (`config :simple_fit, SimpleFit.Gyms.VerificationPolicy,
  country_requirements: %{"PL" => [:registration_number]}`; none is set),
  never from client input or Stripe. Only the optional fields above can be
  made required. Retention of submitted documents is not approved either; nothing
  submitted is deleted automatically.

  Reason codes are the operator's vocabulary for decisions; the owner sees
  the code, never free text.
  """

  @version "sf103-generic-1"

  @base_required [:legal_name, :registration_country]
  @optional [:registration_number, :address_line, :postal_code, :city, :website]

  @min_evidence 1
  @max_evidence 10
  @max_bytes 10 * 1024 * 1024
  @content_types ["application/pdf", "image/jpeg", "image/png"]
  @kinds [:registration_extract, :proof_of_address, :other]

  @reasons %{
    changes_requested: [
      :document_unreadable,
      :document_missing,
      :document_mismatch,
      :details_incomplete,
      :details_mismatch,
      :other
    ],
    rejected: [
      :business_not_verifiable,
      :ineligible_business,
      :details_mismatch,
      :document_mismatch,
      :suspected_fraud,
      :other
    ],
    revoked: [:business_closed, :details_changed, :suspected_fraud, :owner_request, :other]
  }

  @type decision :: :approved | :rejected | :changes_requested | :revoked

  @doc "The current policy version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Every business field the owner may fill in."
  @spec fields() :: [atom()]
  def fields, do: @base_required ++ @optional

  @doc "The fields required to submit, for a registration country (or none yet)."
  @spec required_fields(String.t() | nil) :: [atom()]
  def required_fields(country) when is_binary(country) do
    extra =
      :simple_fit
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:country_requirements, %{})
      |> Map.get(country, [])

    @base_required ++ Enum.filter(@optional, &(&1 in extra))
  end

  def required_fields(nil), do: @base_required

  @doc "The minimum number of uploaded documents to submit."
  @spec min_evidence() :: pos_integer()
  def min_evidence, do: @min_evidence

  @doc "The maximum number of documents of one application (removed ones excluded)."
  @spec max_evidence() :: pos_integer()
  def max_evidence, do: @max_evidence

  @doc "The largest document accepted, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The accepted document content types."
  @spec content_types() :: [String.t()]
  def content_types, do: @content_types

  @doc "The document kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The reason codes of a decision that needs one (`[]` for an approval)."
  @spec reasons(decision()) :: [atom()]
  def reasons(decision), do: Map.get(@reasons, decision, [])

  @doc "Every reason code, sorted."
  @spec all_reasons() :: [atom()]
  def all_reasons, do: @reasons |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()
end
