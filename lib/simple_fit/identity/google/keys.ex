defmodule SimpleFit.Identity.Google.Keys do
  @moduledoc """
  Google's ID-token signing keys (ADR 0013): the
  `SimpleFit.Identity.KeyCache` for
  `https://www.googleapis.com/oauth2/v3/certs` (JWK format). Caching, refresh
  throttling and fail-closed behaviour are documented there.
  """

  alias SimpleFit.Identity.KeyCache

  @options [
    name: __MODULE__,
    base_url: "https://www.googleapis.com",
    path: "/oauth2/v3/certs",
    provider: "google_jwks",
    event: [:simple_fit, :auth, :google, :keys_unavailable],
    config: SimpleFit.Identity.Google
  ]

  @doc false
  def child_spec(_opts), do: KeyCache.child_spec(@options)

  @doc "The public key for `kid` (see `SimpleFit.Identity.KeyCache.fetch/2`)."
  @spec fetch(String.t()) :: {:ok, JOSE.JWK.t()} | {:error, KeyCache.error()}
  def fetch(kid), do: KeyCache.fetch(__MODULE__, kid)

  @doc "Forgets every cached key (operations and tests)."
  @spec flush() :: :ok
  def flush, do: KeyCache.flush(__MODULE__)
end
