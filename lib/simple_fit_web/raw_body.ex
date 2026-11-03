defmodule SimpleFitWeb.RawBody do
  @moduledoc """
  The `Plug.Parsers` body reader of the endpoint (SF-102). For the Stripe
  webhook route only, it keeps the exact bytes it read in
  `conn.private[:raw_body]`, because a webhook signature is computed over
  the raw body and must never be checked against re-serialized JSON. Every
  other route reads its body exactly as before and keeps no copy.
  """

  @webhook_paths ["/api/webhooks/stripe"]

  @doc "Reads the body like `Plug.Conn.read_body/2`, keeping a copy for the webhook route."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{request_path: path} = conn, opts) when path in @webhook_paths do
    case Plug.Conn.read_body(conn, opts) do
      {status, chunk, conn} when status in [:ok, :more] ->
        previous = conn.private[:raw_body] || ""
        {status, chunk, Plug.Conn.put_private(conn, :raw_body, previous <> chunk)}

      error ->
        error
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  @doc "The raw body kept for the webhook route, or `nil`."
  @spec get(Plug.Conn.t()) :: binary() | nil
  def get(%Plug.Conn{private: private}), do: private[:raw_body]
end
