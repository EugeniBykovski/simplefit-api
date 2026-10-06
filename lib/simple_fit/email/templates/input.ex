defmodule SimpleFit.Email.Templates.Input do
  @moduledoc """
  Validation of template variables (ADR 0011), before anything is rendered
  or enqueued.

  Each template declares its variables as Ecto types and validates them with
  the helpers below. Errors name the field and a reason, never the value, so
  a rejected verification URL or code cannot leak through an error or a log.
  """

  import Ecto.Changeset

  @typedoc "Why a variable was rejected."
  @type reason ::
          :required | :invalid_type | :invalid_format | :invalid_url | :too_long | :out_of_range

  @typedoc "A rejected template input: field names and reasons only."
  @type error :: {:invalid_template_data, [{atom(), reason()}]}

  @max_url_length 2048

  @doc """
  Casts and validates `attrs` against `types`. `checks` runs per-template
  validations on the changeset. Returns the validated values.
  """
  @spec validate(map() | keyword(), %{atom() => Ecto.Type.t()}, (Ecto.Changeset.t() ->
                                                                   Ecto.Changeset.t())) ::
          {:ok, map()} | {:error, error()}
  def validate(attrs, types, checks) do
    keys = Map.keys(types)

    changeset =
      {%{}, types}
      |> cast(Map.new(attrs), keys, empty_values: [])
      |> validate_required(keys)
      |> checks.()

    if changeset.valid? do
      {:ok, apply_changes(changeset)}
    else
      {:error, {:invalid_template_data, reasons(changeset)}}
    end
  end

  @doc "A single line of display text: no control characters, at most `max` characters."
  @spec validate_line(Ecto.Changeset.t(), atom(), pos_integer()) :: Ecto.Changeset.t()
  def validate_line(changeset, field, max) do
    changeset
    |> validate_change(field, fn ^field, value ->
      cond do
        String.trim(value) == "" ->
          [{field, {"can't be blank", validation: :required}}]

        control?(value) ->
          [{field, {"has invalid format", validation: :format}}]

        true ->
          []
      end
    end)
    |> validate_length(field, max: max)
  end

  @doc """
  A list of display lines: `1..max_items` items, each a valid
  `validate_line/3` value of at most `max` characters.
  """
  @spec validate_lines(Ecto.Changeset.t(), atom(), pos_integer(), pos_integer()) ::
          Ecto.Changeset.t()
  def validate_lines(changeset, field, max_items, max) do
    validate_change(changeset, field, fn ^field, items ->
      cond do
        items == [] ->
          [{field, {"can't be blank", validation: :required}}]

        length(items) > max_items ->
          [{field, {"has too many items", validation: :length}}]

        Enum.any?(items, &(not line?(&1, max))) ->
          [{field, {"has invalid format", validation: :format}}]

        true ->
          []
      end
    end)
  end

  defp line?(value, max),
    do:
      String.trim(value) != "" and String.length(value) <= max and
        not control?(value)

  # Control and format characters (CR/LF, bidi overrides, line separators).
  defp control?(value), do: String.match?(value, ~r/[\p{Cc}\p{Cf}\x{2028}\x{2029}]/u)

  @doc """
  An absolute `https` URL (or `http` where `allow_http_urls` is configured,
  i.e. local development), with a host and without user info, whitespace or
  control characters. `javascript:`, `data:` and every other scheme are
  rejected.
  """
  @spec validate_url(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if safe_url?(value),
        do: [],
        else: [{field, {"is not a safe absolute URL", validation: :url}}]
    end)
  end

  defp safe_url?(value) do
    allowed = if allow_http?(), do: ["https", "http"], else: ["https"]

    byte_size(value) <= @max_url_length and not String.match?(value, ~r/[\s\p{Cc}]/u) and
      case URI.parse(value) do
        %URI{scheme: scheme, host: host, userinfo: nil} when is_binary(host) and host != "" ->
          scheme in allowed

        _invalid ->
          false
      end
  end

  defp allow_http? do
    Application.get_env(:simple_fit, SimpleFit.Email.Templates, [])[:allow_http_urls] == true
  end

  @validation_reasons %{
    required: :required,
    cast: :invalid_type,
    format: :invalid_format,
    url: :invalid_url,
    length: :too_long,
    number: :out_of_range,
    inclusion: :invalid_format
  }

  defp reasons(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {_message, opts}} ->
      {field, Map.get(@validation_reasons, opts[:validation], :invalid_format)}
    end)
    |> Enum.uniq()
  end
end
