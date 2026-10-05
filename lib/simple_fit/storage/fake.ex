defmodule SimpleFit.Storage.Fake do
  @moduledoc """
  Deterministic `SimpleFit.Storage` adapter for tests and for development
  without AWS credentials.

  Returns URLs on the reserved `.invalid` domain, which never resolves, so a
  fake URL can never upload or download real data. Production configuration
  never selects this adapter.
  """

  @behaviour SimpleFit.Storage

  alias SimpleFit.Storage.Presigned

  @impl true
  def presign(request, config) do
    bucket = config[:bucket] || "simplefit-fake"
    expires_at = DateTime.add(request.now, request.expires_in, :second)

    {:ok,
     %Presigned{
       method: request.method,
       url:
         "https://fake-storage.invalid/#{bucket}/#{config[:key_prefix] || ""}#{request.key}" <>
           "?method=#{request.method}&expires=#{DateTime.to_unix(expires_at)}",
       headers: request.headers,
       expires_at: expires_at
     }}
  end
end
