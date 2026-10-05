defmodule SimpleFit.Storage.ObjectKey do
  @moduledoc """
  Safe object keys for `SimpleFit.Storage`.

  Keys are built from segments (`["avatars", user_id, "original.jpg"]`), never
  from raw user input. Each segment starts with a letter or digit and contains
  only letters, digits, `.`, `_` and `-`, so keys cannot contain path
  traversal (`..`), absolute paths, whitespace, control characters or
  characters that need URL encoding. The environment prefix (for example
  `staging/`) is added by the adapter, not by callers.
  """

  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  @max_bytes 1024

  @typedoc "A validated object key such as `\"avatars/9f1c.../original.jpg\"`."
  @type t :: String.t()

  @doc """
  Joins segments into a key.

      iex> SimpleFit.Storage.ObjectKey.build(["avatars", "u1", "photo.jpg"])
      {:ok, "avatars/u1/photo.jpg"}

      iex> SimpleFit.Storage.ObjectKey.build(["avatars", "../etc"])
      {:error, :invalid_request}
  """
  @spec build([String.t()]) :: {:ok, t()} | {:error, :invalid_request}
  def build([_ | _] = segments) do
    key = Enum.join(segments, "/")
    if Enum.all?(segments, &valid_segment?/1) and valid?(key), do: {:ok, key}, else: invalid()
  end

  def build(_segments), do: invalid()

  @doc "Whether `key` is a valid object key."
  @spec valid?(term()) :: boolean()
  def valid?(key) when is_binary(key) and byte_size(key) in 1..@max_bytes do
    key |> String.split("/") |> Enum.all?(&valid_segment?/1)
  end

  def valid?(_key), do: false

  defp valid_segment?(segment) when is_binary(segment), do: Regex.match?(@segment, segment)
  defp valid_segment?(_segment), do: false

  defp invalid, do: {:error, :invalid_request}
end
