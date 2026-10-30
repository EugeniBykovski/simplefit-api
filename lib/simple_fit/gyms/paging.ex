defmodule SimpleFit.Gyms.Paging do
  @moduledoc """
  Keyset paging for the gym member lists (SF-95). Internal to
  `SimpleFit.Gyms`. A cursor is an opaque base64url `(timestamp, id)` pair;
  params are `limit` (1..100, default 50), `cursor` and an optional
  `status` from a given vocabulary.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset

  @default_limit 50
  @max_limit 100

  @type params :: %{
          limit: pos_integer(),
          cursor: {DateTime.t(), Ecto.UUID.t()} | nil,
          status: atom() | nil
        }

  @doc "Validates paging params; `statuses` is the accepted `status` vocabulary."
  @spec params(map(), [atom()], atom() | nil) :: {:ok, params()} | {:error, Changeset.t()}
  def params(params, statuses, default_status \\ nil) when is_map(params) do
    types = %{limit: :integer, cursor: :string, status: :string}

    changeset =
      {%{limit: @default_limit, cursor: nil, status: nil}, types}
      |> Changeset.cast(Map.take(params, ["limit", "cursor", "status"]), Map.keys(types))
      |> Changeset.validate_number(:limit,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: @max_limit
      )
      |> Changeset.validate_inclusion(:status, Enum.map(statuses, &Atom.to_string/1))

    with %Changeset{valid?: true} <- changeset,
         {:ok, position} <- decode(Changeset.get_field(changeset, :cursor)) do
      status = Changeset.get_field(changeset, :status)

      {:ok,
       %{
         limit: Changeset.get_field(changeset, :limit),
         cursor: position,
         status: if(status, do: String.to_existing_atom(status), else: default_status)
       }}
    else
      %Changeset{} = invalid ->
        {:error, invalid}

      :error ->
        {:error, Changeset.add_error(changeset, :cursor, "is invalid", validation: :format)}
    end
  end

  @doc "Rows after the cursor, for `field` ordered `direction` (then `id`, the same way)."
  @spec seek(Ecto.Queryable.t(), {DateTime.t(), Ecto.UUID.t()} | nil, atom(), :asc | :desc) ::
          Ecto.Query.t()
  def seek(query, nil, _field, _direction), do: Ecto.Queryable.to_query(query)

  def seek(query, {at, id}, field, :asc),
    do:
      from(r in query,
        where: field(r, ^field) > ^at or (field(r, ^field) == ^at and r.id > ^id)
      )

  def seek(query, {at, id}, field, :desc),
    do:
      from(r in query,
        where: field(r, ^field) < ^at or (field(r, ^field) == ^at and r.id < ^id)
      )

  @doc "Splits `limit + 1` rows into a page and the next cursor (on `field`)."
  @spec page([struct()], pos_integer(), atom()) :: {[struct()], String.t() | nil}
  def page(rows, limit, field) do
    {rows, rest} = Enum.split(rows, limit)

    case {rows, rest} do
      {_rows, []} -> {rows, nil}
      _more -> {rows, encode(Map.fetch!(List.last(rows), field), List.last(rows).id)}
    end
  end

  defp encode(%DateTime{} = at, id),
    do: Base.url_encode64("#{DateTime.to_unix(at, :microsecond)}|#{id}", padding: false)

  defp decode(nil), do: {:ok, nil}

  defp decode(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [micros, id] <- String.split(decoded, "|"),
         {micros, ""} <- Integer.parse(micros),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :error
    end
  end
end
