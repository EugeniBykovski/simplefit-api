defmodule SimpleFit.Operators.Cursor do
  @moduledoc """
  Audit log cursors (SF-111, ADR 0029): an opaque, signed position bound to its
  scope. The signed term holds the position `(occurred_at, id)`, a digest of the
  filters it was issued for and the reading operator, and expires after
  `SimpleFit.Operators.Policy.cursor_ttl/0`. A cursor that was altered, expired,
  issued to another operator or used with other filters is refused, so it can't
  widen a query or seek an arbitrary position.

  Signed with `Plug.Crypto.sign/4` and the operators' `secret_key_base`
  (`SECRET_KEY_BASE`) under its own salt.
  """

  alias SimpleFit.Operators.Policy

  @salt "simplefit operator audit cursor v1"

  @doc "A cursor for `position`, bound to `filters` and `operator_id`."
  @spec encode({DateTime.t(), Ecto.UUID.t()}, map(), Ecto.UUID.t()) :: String.t()
  def encode({%DateTime{} = at, id}, filters, operator_id) do
    Plug.Crypto.sign(
      secret_key_base(),
      @salt,
      {:v1, DateTime.to_unix(at, :microsecond), id, scope(filters), operator_id},
      max_age: Policy.cursor_ttl()
    )
  end

  @doc "The position of a valid cursor for this scope, or `:error`."
  @spec decode(String.t(), map(), Ecto.UUID.t()) :: {:ok, {DateTime.t(), Ecto.UUID.t()}} | :error
  def decode(cursor, filters, operator_id) when is_binary(cursor) and byte_size(cursor) <= 1024 do
    expected = scope(filters)

    with {:ok, {:v1, micros, id, ^expected, ^operator_id}} when is_integer(micros) <-
           Plug.Crypto.verify(secret_key_base(), @salt, cursor, max_age: Policy.cursor_ttl()),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :error
    end
  end

  def decode(_cursor, _filters, _operator_id), do: :error

  defp scope(filters),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(Enum.sort(Map.to_list(filters)), [:deterministic])
      )

  defp secret_key_base do
    case Application.get_env(:simple_fit, SimpleFit.Operators, [])[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 64 ->
        secret

      _missing ->
        raise ArgumentError,
              "SimpleFit.Operators: secret_key_base must be at least 64 bytes (SECRET_KEY_BASE)"
    end
  end
end
