defmodule SimpleFitWeb.ChangesetErrors do
  @moduledoc """
  Translates an `Ecto.Changeset` into the `validation_error` details of the
  API error envelope (see `SimpleFitWeb.APIError`):

      %{
        fields: %{"email" => ["can't be blank", "has invalid format"]},
        field_codes: %{"email" => ["required", "invalid_format"]}
      }

    * `fields` - the published SF-2 contract: field name to human-readable
      messages. Unchanged; for display and debugging only.
    * `field_codes` - the machine-readable companion (SF-6): the same entries,
      in the same order, as stable reason codes. Clients branch on these,
      never on messages.

  Codes come from the structured metadata Ecto stores with each error (the
  `:validation`, `:kind`, `:constraint` and `:type` options), never from the
  message text. Nested changesets (embeds and associations) are flattened to
  dotted paths: `address.city`, `rounds.0.duration`. Raw changesets, values
  and database details never leave this module.
  """

  @typedoc "Validation details for the `validation_error` envelope."
  @type details :: %{
          fields: %{optional(String.t()) => [String.t()]},
          field_codes: %{optional(String.t()) => [String.t()]}
        }

  # Stable reason codes. Additive only: clients treat unknown codes like
  # `invalid`. Domain-specific codes belong to the domain ticket that needs them.
  @reason_codes ~w(
    required invalid_format too_short too_long wrong_length out_of_range
    invalid_choice invalid_type already_exists does_not_exist
    must_be_accepted does_not_match too_young immutable invalid
  )

  @doc "All validation reason codes that `details/1` can produce."
  @spec reason_codes() :: [String.t()]
  def reason_codes, do: @reason_codes

  @doc "The `validation_error` details for an invalid changeset."
  @spec details(Ecto.Changeset.t()) :: details()
  def details(%Ecto.Changeset{} = changeset) do
    entries =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, opts} -> {message, opts} end)
      |> flatten(nil)

    %{
      fields: Map.new(entries, fn {field, errors} -> {field, Enum.map(errors, &message/1)} end),
      field_codes:
        Map.new(entries, fn {field, errors} -> {field, Enum.map(errors, &reason_code/1)} end)
    }
  end

  # traverse_errors/2 returns, per field, a list of errors, a nested map (embeds
  # and associations) or a list of nested maps (has_many / embeds_many).
  defp flatten(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} -> flatten(value, path(prefix, key)) end)
  end

  # Ecto prepends errors; reverse so each field lists them in the order the
  # validations ran. Messages and codes come from this same list, so they stay
  # aligned entry by entry.
  defp flatten([{message, opts} | _] = errors, prefix) when is_binary(message) and is_list(opts),
    do: [{prefix, Enum.reverse(errors)}]

  defp flatten(list, prefix) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> flatten(nested, path(prefix, index)) end)
  end

  defp path(nil, key), do: to_string(key)
  defp path(prefix, key), do: "#{prefix}.#{key}"

  # Interpolates Ecto's "%{count}"-style placeholders from the error options.
  defp message({message, opts}) do
    Regex.replace(~r/%{(\w+)}/, message, fn placeholder, key ->
      case List.keyfind(opts, String.to_existing_atom(key), 0) do
        {_key, value} -> to_string(value)
        nil -> placeholder
      end
    end)
  rescue
    ArgumentError -> message
  end

  # Ecto validation (from the `:validation` option) to reason code. `:length`
  # depends on `:kind`; constraint errors carry `:constraint` instead.
  @validation_codes %{
    required: "required",
    format: "invalid_format",
    number: "out_of_range",
    inclusion: "invalid_choice",
    subset: "invalid_choice",
    exclusion: "invalid_choice",
    cast: "invalid_type",
    unsafe_unique: "already_exists",
    acceptance: "must_be_accepted",
    confirmation: "does_not_match",
    too_young: "too_young",
    immutable: "immutable"
  }
  @length_codes %{min: "too_short", max: "too_long", is: "wrong_length"}
  @constraint_codes %{
    unique: "already_exists",
    foreign: "does_not_exist",
    assoc: "does_not_exist"
  }

  defp reason_code({_message, opts}) do
    cond do
      opts[:validation] == :length -> Map.get(@length_codes, opts[:kind], "invalid")
      code = @validation_codes[opts[:validation]] -> code
      code = @constraint_codes[opts[:constraint]] -> code
      opts[:type] -> "invalid_type"
      true -> "invalid"
    end
  end
end
