defmodule SimpleFit.Storage do
  @moduledoc """
  Object storage boundary (private files: avatars, gym media, training and
  sparring video, documents, sponsorship assets).

  Clients transfer bytes directly to and from storage with presigned URLs;
  Phoenix never proxies uploads or downloads. Domain contexts decide *what*
  may be stored (owner, purpose, allowed content types, size limits), build
  the key with `SimpleFit.Storage.ObjectKey`, then call this module:

      {:ok, key} = ObjectKey.build(["avatars", user.id, "original.jpg"])
      {:ok, upload} = Storage.presign_upload(key, content_type: "image/jpeg", content_length: 48_213)

  The adapter comes from configuration (`config :simple_fit, SimpleFit.Storage`):
  `SimpleFit.Storage.S3` in production, `SimpleFit.Storage.Fake` in test and
  in development without AWS credentials. Buckets are private; there are no
  public URLs.
  """

  require Logger

  alias SimpleFit.{HTTP, Provider}
  alias SimpleFit.Storage.{ObjectKey, Presigned}

  # S3 limits a single PUT to 5 GiB; larger media will need multipart uploads.
  @max_content_length 5 * 1024 * 1024 * 1024
  @max_expires_in 3_600
  @default_upload_expires_in 900
  @default_download_expires_in 300
  @content_type ~r{\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\z}

  @typedoc """
  A normalized presign request handed to adapters: method, key, signed
  headers, lifetime in seconds and the signing time.
  """
  @type request :: %{
          required(:method) => Presigned.method(),
          required(:key) => ObjectKey.t(),
          required(:headers) => %{optional(String.t()) => String.t()},
          required(:expires_in) => pos_integer(),
          required(:now) => DateTime.t(),
          optional(:query) => [{String.t(), String.t()}]
        }

  @doc "Signs `request` with the adapter `config` (from application config)."
  @callback presign(request(), config :: keyword()) ::
              {:ok, Presigned.t()} | {:error, Provider.error()}

  @doc """
  Presigns a direct upload (`PUT`) of exactly `content_length` bytes of
  `content_type` to `key`.

  `content-type` and `content-length` are signed, so storage rejects an upload
  with a different type or size. Callers enforce their own (smaller) limits
  before presigning.

  ## Options

    * `:content_type` (required) - e.g. `"image/jpeg"`
    * `:content_length` (required) - exact size in bytes, at most 5 GiB
    * `:expires_in` - lifetime in seconds, 1..3600, default 900
  """
  @spec presign_upload(ObjectKey.t(), keyword()) ::
          {:ok, Presigned.t()} | {:error, Provider.error()}
  def presign_upload(key, opts) do
    with :ok <- validate_key(key),
         {:ok, content_type} <- fetch_content_type(opts),
         {:ok, content_length} <- fetch_content_length(opts),
         {:ok, expires_in} <- fetch_expires_in(opts, @default_upload_expires_in) do
      presign(%{
        method: :put,
        key: key,
        headers: %{
          "content-type" => content_type,
          "content-length" => Integer.to_string(content_length)
        },
        expires_in: expires_in,
        now: now(opts)
      })
    end
  end

  @doc """
  Presigns a private download (`GET`) of `key`.

  ## Options

    * `:expires_in` - lifetime in seconds, 1..3600, default 300
    * `:attachment` - `true` signs `response-content-disposition: attachment` and
      `response-content-type: application/octet-stream` into the URL (SF-116), so a
      browser saves an untrusted file instead of rendering or sniffing it
  """
  @spec presign_download(ObjectKey.t(), keyword()) ::
          {:ok, Presigned.t()} | {:error, Provider.error()}
  def presign_download(key, opts \\ []) do
    with :ok <- validate_key(key),
         {:ok, expires_in} <- fetch_expires_in(opts, @default_download_expires_in) do
      query =
        if Keyword.get(opts, :attachment, false),
          do: [
            {"response-content-disposition", "attachment"},
            {"response-content-type", "application/octet-stream"}
          ],
          else: []

      presign(%{
        method: :get,
        key: key,
        headers: %{},
        expires_in: expires_in,
        now: now(opts),
        query: query
      })
    end
  end

  @doc """
  Reads an object's size and content type from storage (SF-103), with a
  short-lived presigned `HEAD` sent by the server: `{:ok, %{content_length,
  content_type}}`, or `{:error, :not_found}` when storage has no such object
  (`403` counts as missing: a bucket without list permission answers so).

  This is how a domain verifies that a client really uploaded what it was
  allowed to before attaching the object. The request goes through
  `SimpleFit.HTTP` (`:req_options` from the storage configuration stub it in
  tests); it never follows a redirect and never logs the URL.
  """
  @spec stat(ObjectKey.t(), keyword()) ::
          {:ok, %{content_length: non_neg_integer(), content_type: String.t() | nil}}
          | {:error, :not_found | Provider.error()}
  def stat(key, opts \\ []) do
    with :ok <- validate_key(key),
         {:ok, presigned} <- presign(server_request(:head, key, opts)) do
      case send_signed(presigned) do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {:ok,
           %{
             content_length: content_length(response),
             content_type: header(response, "content-type")
           }}

        {:ok, %Req.Response{status: status}} when status in [403, 404] ->
          {:error, :not_found}

        other ->
          HTTP.normalize(other, "storage") |> provider_error()
      end
    end
  end

  @doc """
  Deletes an object from storage with a short-lived presigned `DELETE` sent
  by the server (SF-103: removed and abandoned uploads). `:ok` also when the
  object is already gone.
  """
  @spec delete(ObjectKey.t(), keyword()) :: :ok | {:error, Provider.error()}
  def delete(key, opts \\ []) do
    with :ok <- validate_key(key),
         {:ok, presigned} <- presign(server_request(:delete, key, opts)) do
      case send_signed(presigned) do
        {:ok, %Req.Response{status: status}} when status in 200..299 or status == 404 -> :ok
        other -> HTTP.normalize(other, "storage") |> provider_error()
      end
    end
  end

  # Server-side requests are signed for one minute: they are sent at once.
  defp server_request(method, key, opts),
    do: %{method: method, key: key, headers: %{}, expires_in: 60, now: now(opts)}

  defp send_signed(%Presigned{method: method, url: url}) do
    {_adapter, config} = adapter_config()

    [url: url, method: method, decode_body: false]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> HTTP.new()
    |> Req.request()
  end

  defp content_length(response) do
    case Integer.parse(header(response, "content-length") || "") do
      {length, ""} when length >= 0 -> length
      _missing -> 0
    end
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp provider_error({:error, reason}), do: {:error, reason}

  defp provider_error({:ok, %Req.Response{status: status}}) do
    Logger.warning("unexpected storage response", provider: "storage", status: status)
    {:error, :unavailable}
  end

  defp presign(request) do
    {adapter, config} = adapter_config()

    :telemetry.span([:simple_fit, :storage, :presign], %{adapter: adapter}, fn ->
      result = adapter.presign(request, config)
      {result, %{adapter: adapter, method: request.method, result: result_tag(result)}}
    end)
  end

  defp adapter_config do
    config = Application.get_env(:simple_fit, __MODULE__, [])
    {Keyword.fetch!(config, :adapter), config}
  end

  defp validate_key(key), do: if(ObjectKey.valid?(key), do: :ok, else: {:error, :invalid_request})

  defp fetch_content_type(opts) do
    case Keyword.get(opts, :content_type) do
      type when is_binary(type) ->
        if Regex.match?(@content_type, type), do: {:ok, type}, else: invalid()

      _missing ->
        invalid()
    end
  end

  defp fetch_content_length(opts) do
    case Keyword.get(opts, :content_length) do
      length when is_integer(length) and length in 1..@max_content_length -> {:ok, length}
      _invalid -> invalid()
    end
  end

  defp fetch_expires_in(opts, default) do
    case Keyword.get(opts, :expires_in, default) do
      seconds when is_integer(seconds) and seconds in 1..@max_expires_in -> {:ok, seconds}
      _invalid -> invalid()
    end
  end

  # `:now` is accepted for deterministic tests only.
  defp now(opts), do: Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:second) end)

  defp result_tag({:ok, _presigned}), do: :ok
  defp result_tag({:error, reason}), do: reason

  defp invalid, do: {:error, :invalid_request}
end
