defmodule SimpleFit.Identity do
  @moduledoc """
  Provider identity verification (ADR 0013): proves, independently of the
  client, that a sign-in credential issued by an external identity provider
  is genuine, and returns the provider's stable subject. Provider
  credentials end here: they are never SimpleFit session credentials
  (ADR 0010), and nothing a client claims about a person (email, name) is
  trusted.

  Providers: `:google` (`SimpleFit.Identity.Google`, ADR 0013) and `:apple`
  (`SimpleFit.Identity.Apple`, ADR 0014). Claim verification stays
  provider-specific; only signing-key caching is shared
  (`SimpleFit.Identity.KeyCache`).

  Results:

    * `{:ok, %{provider: provider, subject: subject}}`
    * `{:error, {:rejected, reason}}` - not a valid credential (`reason` is a
      bounded atom, safe for telemetry)
    * `{:error, :unavailable}` - the provider's signing keys could not be
      obtained (fail closed)
    * `{:error, :not_configured}` - the provider is not configured here
  """

  alias SimpleFit.Identity.{Apple, Google}

  @spec verify(:google, term()) :: Google.result()
  @spec verify(:apple, Apple.credential()) :: Apple.result()
  def verify(:google, token), do: Google.verify(token)
  def verify(:apple, credential), do: Apple.verify(credential)
end
