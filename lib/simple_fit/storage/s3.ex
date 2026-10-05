defmodule SimpleFit.Storage.S3 do
  @moduledoc """
  `SimpleFit.Storage` adapter for AWS S3 (and S3-compatible endpoints such as
  MinIO for local development).

  Presigned URLs are computed locally with AWS Signature Version 4
  (`Req.Utils.aws_sigv4_url/1`); presigning makes no network call. URLs are
  virtual-hosted style (`https://<bucket>.s3.<region>.amazonaws.com/<key>`),
  or path style under `:endpoint` when one is configured.

  ## Configuration (`config :simple_fit, SimpleFit.Storage`)

    * `:bucket`, `:region`, `:access_key_id`, `:secret_access_key` - required
    * `:session_token` - temporary credentials (STS / assumed roles)
    * `:endpoint` - S3-compatible base URL, e.g. `http://localhost:9000`
    * `:key_prefix` - environment prefix prepended to every key, e.g. `staging/`

  Missing required values make every call return `{:error,
  :configuration_error}` (fail closed). Credentials stay on the server: only
  the signed URL reaches clients.
  """

  @behaviour SimpleFit.Storage

  require Logger

  alias SimpleFit.Storage.Presigned

  @required [:bucket, :region, :access_key_id, :secret_access_key]

  @impl true
  def presign(request, config) do
    case Enum.reject(@required, &present?(config[&1])) do
      [] ->
        {:ok, sign(request, config)}

      missing ->
        Logger.error("storage is not configured", provider: "s3", missing: missing)
        {:error, :configuration_error}
    end
  end

  defp sign(request, config) do
    query =
      case config[:session_token] do
        token when is_binary(token) and token != "" -> [{"X-Amz-Security-Token", token}]
        _none -> []
      end

    url =
      Req.Utils.aws_sigv4_url(
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: config[:region],
        service: :s3,
        datetime: request.now,
        method: request.method,
        url: object_url(request.key, config),
        expires: request.expires_in,
        headers: Map.to_list(request.headers),
        query: query
      )

    %Presigned{
      method: request.method,
      url: to_string(url),
      headers: request.headers,
      expires_at: DateTime.add(request.now, request.expires_in, :second)
    }
  end

  defp object_url(key, config) do
    full_key = (config[:key_prefix] || "") <> key

    case config[:endpoint] do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        "#{String.trim_trailing(endpoint, "/")}/#{config[:bucket]}/#{full_key}"

      _aws ->
        "https://#{config[:bucket]}.s3.#{config[:region]}.amazonaws.com/#{full_key}"
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
