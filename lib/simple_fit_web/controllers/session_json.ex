defmodule SimpleFitWeb.SessionJSON do
  @moduledoc """
  JSON rendering of session credentials (`SessionTokens`). Reused by every
  flow that issues credentials (refresh now; email, Google and Apple sign-in
  later). The refresh token appears in the body only for the body transport.
  """

  alias SimpleFit.Accounts.Sessions
  alias SimpleFitWeb.SessionTransport

  @spec show(%{credentials: Sessions.credentials(), transport: SessionTransport.transport()}) ::
          map()
  def show(%{credentials: credentials, transport: transport}) do
    base = %{
      token_type: "Bearer",
      access_token: credentials.access_token,
      access_token_expires_at: DateTime.to_iso8601(credentials.access_token_expires_at),
      refresh_token_expires_at: DateTime.to_iso8601(credentials.refresh_token_expires_at),
      refresh_token_transport: Atom.to_string(transport)
    }

    case transport do
      :body -> Map.put(base, :refresh_token, credentials.refresh_token)
      :cookie -> base
    end
  end
end
