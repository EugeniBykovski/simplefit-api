defmodule SimpleFit.HTTP do
  @moduledoc """
  The canonical outbound HTTP client for provider adapters, built on `Req`.

  Only adapters (`SimpleFit.Email.Resend`, future payment/identity/push
  adapters) make outbound HTTP calls, always through `new/1` and
  `normalize/2`. Domain code never builds HTTP clients.

  Defaults, chosen to fail fast and fail closed:

    * TLS: peer certificate and hostname verification against the OS trust
      store (Req/Mint default). Never disable it.
    * Timeouts: 5 s to connect, 15 s to receive. Callers may lower them.
    * `retry: false`: retries belong to the caller (an Oban job with bounded
      attempts and an idempotency key), so one failure cannot multiply into a
      request storm or a duplicate side effect.
    * `redirect: false`: provider APIs do not redirect; following redirects
      would allow a response to steer requests to arbitrary hosts.

  `base_url` must be a constant or trusted configuration. Never build a
  request URL from user input (SSRF).

  Tests stub providers without network access through the adapter's
  `:req_options` configuration, e.g. `plug: {Req.Test, SimpleFit.Email.Resend}`.
  """

  require Logger

  alias SimpleFit.Provider

  @default_options [
    connect_options: [timeout: 5_000],
    receive_timeout: 15_000,
    retry: false,
    redirect: false
  ]

  @doc """
  Builds a `Req.Request` with the SimpleFit defaults.

  `options` are Req options (`:base_url`, `:headers`, `:auth`, ...); they
  override the defaults, so adapters can pass test plugs or shorter timeouts.
  """
  @spec new(keyword()) :: Req.Request.t()
  def new(options) do
    Req.new(Keyword.merge(@default_options, options))
  end

  @doc """
  Translates a `Req` result into `{:ok, response}` or `{:error, reason}`.

  2xx responses are returned unchanged for the adapter to decode. Every other
  status and transport failure becomes a `t:SimpleFit.Provider.error/0` and is
  logged at `:warning` with the provider name, status and reason only: never
  the body, headers or URL.
  """
  @spec normalize({:ok, Req.Response.t()} | {:error, Exception.t()}, String.t()) ::
          {:ok, Req.Response.t()} | {:error, Provider.error()}
  def normalize({:ok, %Req.Response{status: status} = response}, _provider)
      when status in 200..299,
      do: {:ok, response}

  def normalize({:ok, %Req.Response{status: status}}, provider) do
    reason = reason_for_status(status)
    Logger.warning("provider request failed", provider: provider, status: status, reason: reason)
    {:error, reason}
  end

  def normalize({:error, exception}, provider) do
    reason = reason_for_exception(exception)
    Logger.warning("provider request failed", provider: provider, reason: reason)
    {:error, reason}
  end

  @doc false
  @spec reason_for_status(100..599) :: Provider.error()
  def reason_for_status(status) when status in [401, 403], do: :unauthorized
  def reason_for_status(408), do: :timeout
  def reason_for_status(429), do: :rate_limited
  def reason_for_status(status) when status in 400..499, do: :invalid_request
  def reason_for_status(_status), do: :unavailable

  defp reason_for_exception(%Req.TransportError{reason: :timeout}), do: :timeout
  defp reason_for_exception(_exception), do: :unavailable
end
