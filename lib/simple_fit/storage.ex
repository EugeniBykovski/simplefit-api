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

  alias SimpleFit.Provider
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
          method: :put | :get,
          key: ObjectKey.t(),
          headers: %{optional(String.t()) => String.t()},
          expires_in: pos_integer(),
          now: DateTime.t()
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
  """
  @spec presign_download(ObjectKey.t(), keyword()) ::
          {:ok, Presigned.t()} | {:error, Provider.error()}
  def presign_download(key, opts \\ []) do
    with :ok <- validate_key(key),
         {:ok, expires_in} <- fetch_expires_in(opts, @default_download_expires_in) do
      presign(%{method: :get, key: key, headers: %{}, expires_in: expires_in, now: now(opts)})
    end
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
