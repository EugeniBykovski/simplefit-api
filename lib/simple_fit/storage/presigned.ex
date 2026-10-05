defmodule SimpleFit.Storage.Presigned do
  @moduledoc """
  A time-limited, signed request a client performs directly against object
  storage (uploads and downloads never pass through Phoenix).

    * `method` - HTTP method the client must use (`:put` or `:get`).
    * `url` - the signed URL. It is a bearer credential until `expires_at`:
      return it only to the client that asked for it and never log it.
      `inspect/1` redacts it.
    * `headers` - headers the client must send unchanged (they are part of
      the signature, e.g. `content-type` and `content-length` for uploads).
    * `expires_at` - when the URL stops working.
  """

  @derive {Inspect, except: [:url]}
  @enforce_keys [:method, :url, :headers, :expires_at]
  defstruct [:method, :url, :headers, :expires_at]

  @type t :: %__MODULE__{
          method: :put | :get,
          url: String.t(),
          headers: %{optional(String.t()) => String.t()},
          expires_at: DateTime.t()
        }
end
