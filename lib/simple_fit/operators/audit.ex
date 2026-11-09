defmodule SimpleFit.Operators.Audit do
  @moduledoc """
  Writes `SimpleFit.Operators.AuditEvent` rows. Allowed events are written inside
  the transaction of the change they record; refusals are written in their own
  transaction, after the refused one rolled back.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Operators.AuditEvent
  alias SimpleFit.Repo

  @type context :: %{
          optional(:request_id) => String.t() | nil,
          optional(:session_id) => Ecto.UUID.t() | nil,
          optional(:operation_id) => Ecto.UUID.t() | nil
        }

  @doc "Inserts one event. `attrs` holds the event's own fields; `ctx` the request's."
  @spec record!(map(), context()) :: :ok
  def record!(attrs, ctx \\ %{}) do
    fields =
      Map.merge(
        %{
          occurred_at: DateTime.utc_now(),
          authority: :platform_operator,
          request_id: ctx |> Map.get(:request_id) |> request_id(),
          session_id: Map.get(ctx, :session_id),
          operation_id: Map.get(ctx, :operation_id)
        },
        attrs
      )

    _event = Repo.insert!(struct(AuditEvent, fields), log: false)
    :ok
  end

  @doc "Newest first, at most `limit`, strictly before `before` when given."
  @spec list(pos_integer(), DateTime.t() | nil) :: [AuditEvent.t()]
  def list(limit, before) do
    query = from(e in AuditEvent, order_by: [desc: e.occurred_at, desc: e.id], limit: ^limit)
    query = if before, do: from(e in query, where: e.occurred_at < ^before), else: query
    Repo.all(query, log: false)
  end

  defp request_id(id) when is_binary(id) and byte_size(id) <= 200, do: id
  defp request_id(_id), do: nil
end
