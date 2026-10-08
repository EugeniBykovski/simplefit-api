defmodule SimpleFitWeb.AccountProfileJSON do
  @moduledoc """
  JSON rendering for `SimpleFitWeb.AccountProfileController`
  (`AccountProfileResponse`). Fields are picked explicitly; ids, the user id
  and internal timestamps are not exposed.
  """

  alias SimpleFit.Accounts.Registration

  @spec show(%{registration: Registration.t()}) :: %{account_profile: map()}
  def show(%{registration: %{profile: profile, consents: consents} = registration}) do
    %{
      account_profile: %{
        registration: %{
          status: registration.status,
          completed_at: iso8601(profile && profile.registration_completed_at),
          missing_requirements: registration.missing_requirements
        },
        full_name: profile && profile.full_name,
        date_of_birth: profile && profile.date_of_birth && Date.to_iso8601(profile.date_of_birth),
        consents: %{terms: legal(consents.terms), privacy: legal(consents.privacy)},
        product_news: %{
          subscribed: consents.product_news.subscribed,
          updated_at: iso8601(consents.product_news.updated_at)
        }
      }
    }
  end

  defp legal(state) do
    %{
      accepted: state.accepted,
      accepted_version: state.accepted_version,
      accepted_at: iso8601(state.accepted_at),
      current_version: state.current_version,
      current: state.current
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
