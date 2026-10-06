defmodule SimpleFit.Identity.Apple.Keys do
  @moduledoc """
  Apple's ID-token signing keys (ADR 0014): the `SimpleFit.Identity.KeyCache`
  for `https://appleid.apple.com/auth/keys` (JWK format). Apple answers with
  `Cache-Control: no-store`, so keys are kept for the cache's 300 s default
  rather than fetched per request; an unknown `kid` still refreshes (at most
  once per 60 s).
  """

  alias SimpleFit.Identity.KeyCache

  @options [
    name: __MODULE__,
    base_url: "https://appleid.apple.com",
    path: "/auth/keys",
    provider: "apple_jwks",
    event: [:simple_fit, :auth, :apple, :keys_unavailable],
    config: SimpleFit.Identity.Apple
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
