defmodule SimpleFit.Operators.Audit do
  @moduledoc """
  Writes and reads `SimpleFit.Operators.AuditEvent` rows. Allowed events are written
  inside the transaction of the change they record; refusals are written in their
  own transaction, after the refused one rolled back.

  Reads (SF-111) are keyset pages, newest first, ordered by `(occurred_at, id)` so
  events with the same timestamp keep a stable order. Filters are a fixed set of
  columns compared for equality (and a time range); no sort, column or expression
  comes from a request.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Operators.AuditEvent
  alias SimpleFit.Repo

  @type context :: %{
          optional(:request_id) => String.t() | nil,
          optional(:session_id) => Ecto.UUID.t() | nil,
          optional(:operation_id) => Ecto.UUID.t() | nil
        }

  @type filters :: %{
          optional(:actor_operator_id) => Ecto.UUID.t(),
          optional(:action) => String.t(),
          optional(:command) => String.t(),
          optional(:target_type) => String.t(),
          optional(:target_id) => Ecto.UUID.t(),
          optional(:outcome) => atom(),
          optional(:occurred_after) => DateTime.t(),
          optional(:occurred_before) => DateTime.t()
        }

  @type position :: {DateTime.t(), Ecto.UUID.t()}

  @equality [:actor_operator_id, :action, :command, :target_type, :target_id, :outcome]

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

  @doc """
  One page, newest first: at most `limit` events matching `filters`, strictly after
  `position` in that order. Returns the events and the position of the last one when
  more follow.
  """
  @spec page(filters(), pos_integer(), position() | nil) :: {[AuditEvent.t()], position() | nil}
  def page(filters, limit, position) do
    query =
      Enum.reduce(@equality, AuditEvent, fn field, query ->
        case Map.fetch(filters, field) do
          {:ok, value} -> from(e in query, where: field(e, ^field) == ^value)
          :error -> query
        end
      end)

    query =
      query
      |> range(:occurred_after, filters)
      |> range(:occurred_before, filters)
      |> after_position(position)

    rows =
      Repo.all(
        from(e in query, order_by: [desc: e.occurred_at, desc: e.id], limit: ^(limit + 1)),
        log: false
      )

    case Enum.split(rows, limit) do
      {page, []} -> {page, nil}
      {page, _more} -> {page, {List.last(page).occurred_at, List.last(page).id}}
    end
  end

  @doc "One event by id."
  @spec get(Ecto.UUID.t()) :: AuditEvent.t() | nil
  def get(id), do: Repo.get(AuditEvent, id, log: false)

  defp range(query, :occurred_after, %{occurred_after: at}),
    do: from(e in query, where: e.occurred_at >= ^at)

  defp range(query, :occurred_before, %{occurred_before: at}),
    do: from(e in query, where: e.occurred_at < ^at)

  defp range(query, _bound, _filters), do: query

  defp after_position(query, nil), do: query

  defp after_position(query, {at, id}),
    do: from(e in query, where: e.occurred_at < ^at or (e.occurred_at == ^at and e.id < ^id))

  defp request_id(id) when is_binary(id) and byte_size(id) <= 200, do: id
  defp request_id(_id), do: nil
end
