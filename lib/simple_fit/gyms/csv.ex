defmodule SimpleFit.Gyms.Csv do
  @moduledoc """
  A small, strict RFC 4180 reader for member lists (SF-95). Internal to
  `SimpleFit.Gyms`. In memory only: nothing is written, cached or logged,
  and errors never quote the content (only a line number and a code).

    * UTF-8 only (a leading byte-order mark is dropped);
    * `,`, `;` (spreadsheets in Polish and other locales) or tab, detected
      from the header line outside quotes;
    * quoted fields with doubled quotes, embedded delimiters and line
      breaks; `\\r\\n`, `\\n` or `\\r` line ends; blank lines are skipped;
    * the first record is the header.

  Limits (a reader of contact lists, not a data pipeline): 1 MB, 1,000 data
  rows, 30 columns, 500 bytes per field.
  """

  @max_bytes 1_000_000
  @max_rows 1_000
  @max_columns 30
  @max_field 500

  @type error ::
          :empty
          | :too_large
          | :invalid_encoding
          | :too_many_rows
          | :too_many_columns
          | {:field_too_long, pos_integer()}
          | {:unterminated_quote, pos_integer()}
          | {:stray_quote, pos_integer()}
          | :duplicate_header
          | :blank_header

  @type parsed :: %{
          delimiter: String.t(),
          header: [String.t()],
          rows: [{pos_integer(), [String.t()]}]
        }

  @doc "The limits, for the API documentation."
  @spec limits() :: map()
  def limits,
    do: %{
      max_bytes: @max_bytes,
      max_rows: @max_rows,
      max_columns: @max_columns,
      max_field: @max_field
    }

  @doc """
  Parses `content`. Rows are `{line, fields}` (the line where the record
  starts), padded or kept as read: callers check widths.
  """
  @spec parse(term()) :: {:ok, parsed()} | {:error, error()}
  def parse(content) when is_binary(content) and byte_size(content) > @max_bytes,
    do: {:error, :too_large}

  def parse(content) when is_binary(content) do
    content = strip_bom(content)

    cond do
      not String.valid?(content) -> {:error, :invalid_encoding}
      String.trim(content) == "" -> {:error, :empty}
      true -> do_parse(content)
    end
  end

  def parse(_content), do: {:error, :empty}

  defp do_parse(content) do
    delimiter = detect_delimiter(content)

    with {:ok, records} <- records(content, delimiter),
         [{_line, header} | rows] <- Enum.reject(records, &blank?/1),
         header = Enum.map(header, &String.trim/1),
         :ok <- check_header(header),
         :ok <- check_rows(rows) do
      {:ok, %{delimiter: delimiter, header: header, rows: rows}}
    else
      [] -> {:error, :empty}
      {:error, _} = error -> error
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp blank?({_line, fields}), do: Enum.all?(fields, &(String.trim(&1) == ""))

  defp check_header(header) do
    cond do
      length(header) > @max_columns ->
        {:error, :too_many_columns}

      Enum.any?(header, &(&1 == "")) ->
        {:error, :blank_header}

      length(Enum.uniq_by(header, &String.downcase/1)) != length(header) ->
        {:error, :duplicate_header}

      true ->
        :ok
    end
  end

  defp check_rows(rows) do
    cond do
      length(rows) > @max_rows ->
        {:error, :too_many_rows}

      Enum.any?(rows, fn {_line, fields} -> length(fields) > @max_columns end) ->
        {:error, :too_many_columns}

      true ->
        :ok
    end
  end

  # The delimiter most frequent in the first line, outside quotes.
  defp detect_delimiter(content) do
    {counts, _quoted} =
      content
      |> first_line()
      |> String.graphemes()
      |> Enum.reduce({%{"," => 0, ";" => 0, "\t" => 0}, false}, fn
        "\"", {counts, quoted} ->
          {counts, not quoted}

        char, {counts, false} when is_map_key(counts, char) ->
          {Map.update!(counts, char, &(&1 + 1)), false}

        _char, acc ->
          acc
      end)

    {delimiter, _} =
      Enum.max_by([{",", counts[","]}, {";", counts[";"]}, {"\t", counts["\t"]}], &elem(&1, 1))

    delimiter
  end

  defp first_line(content), do: content |> String.split(["\r\n", "\n", "\r"], parts: 2) |> hd()

  ## Records

  defp records(content, <<d>>), do: read(content, d, 1, 1, [], [], [])

  # read(rest, delimiter, line, record_line, field_acc (reversed iodata), fields, records)
  defp read(<<>>, _d, _line, _start, [], [], records), do: {:ok, Enum.reverse(records)}

  defp read(<<>>, _d, line, start, field, fields, records) do
    with {:ok, value} <- field_value(field, line),
         do: {:ok, Enum.reverse([{start, Enum.reverse([value | fields])} | records])}
  end

  defp read(<<"\"", rest::binary>>, d, line, start, [], fields, records) do
    case quoted(rest, line, []) do
      {:ok, value, rest, line} -> after_quoted(rest, d, line, start, value, fields, records)
      {:error, _} = error -> error
    end
  end

  defp read(<<"\"", _::binary>>, _d, line, _start, _field, _fields, _records),
    do: {:error, {:stray_quote, line}}

  defp read(<<d, rest::binary>>, d, line, start, field, fields, records) do
    with {:ok, value} <- field_value(field, line),
         do: read(rest, d, line, start, [], [value | fields], records)
  end

  defp read(<<"\r\n", rest::binary>>, d, line, start, field, fields, records),
    do: next_record(rest, d, line, start, field, fields, records)

  defp read(<<c, rest::binary>>, d, line, start, field, fields, records) when c in [?\n, ?\r],
    do: next_record(rest, d, line, start, field, fields, records)

  defp read(<<c, rest::binary>>, d, line, start, field, fields, records),
    do: read(rest, d, line, start, [field, c], fields, records)

  defp next_record(rest, d, line, start, field, fields, records) do
    with {:ok, value} <- field_value(field, line) do
      read(rest, d, line + 1, line + 1, [], [], [
        {start, Enum.reverse([value | fields])} | records
      ])
    end
  end

  defp field_value(field, line) do
    value = IO.iodata_to_binary(field)
    if byte_size(value) > @max_field, do: {:error, {:field_too_long, line}}, else: {:ok, value}
  end

  # After a closing quote: a delimiter, a line end or the end of input.
  defp after_quoted(rest, d, line, start, value, fields, records) do
    cond do
      byte_size(value) > @max_field ->
        {:error, {:field_too_long, line}}

      rest == "" ->
        {:ok, Enum.reverse([{start, Enum.reverse([value | fields])} | records])}

      true ->
        case rest do
          <<^d, rest::binary>> ->
            read(rest, d, line, start, [], [value | fields], records)

          <<"\r\n", rest::binary>> ->
            read(rest, d, line + 1, line + 1, [], [], [
              {start, Enum.reverse([value | fields])} | records
            ])

          <<c, rest::binary>> when c in [?\n, ?\r] ->
            read(rest, d, line + 1, line + 1, [], [], [
              {start, Enum.reverse([value | fields])} | records
            ])

          _ ->
            {:error, {:stray_quote, line}}
        end
    end
  end

  defp quoted(<<"\"\"", rest::binary>>, line, acc), do: quoted(rest, line, [acc, ?"])
  defp quoted(<<"\"", rest::binary>>, line, acc), do: {:ok, IO.iodata_to_binary(acc), rest, line}
  defp quoted(<<"\r\n", rest::binary>>, line, acc), do: quoted(rest, line + 1, [acc, "\r\n"])

  defp quoted(<<c, rest::binary>>, line, acc) when c in [?\n, ?\r],
    do: quoted(rest, line + 1, [acc, c])

  defp quoted(<<c, rest::binary>>, line, acc), do: quoted(rest, line, [acc, c])
  defp quoted(<<>>, line, _acc), do: {:error, {:unterminated_quote, line}}
end
