defmodule SimpleFitWeb.ApiSpec.Validation do
  @moduledoc """
  Contract-level checks on the OpenAPI spec that `open_api_spex` does not
  enforce on its own. Used by `mix openapi.check` and the test suite.

    * every operation has a summary, at least one declared tag and a unique
      camelCase `operationId` (generated clients use it as the method name)
    * every example in `components.schemas` and `components.responses`
      validates against its schema, so documentation cannot drift from the
      shapes it describes

  Structural validation against the OpenAPI 3 specification itself is done
  by Redocly CLI (see redocly.yaml and README.md).
  """

  alias OpenApiSpex.{Components, MediaType, OpenApi, Operation, PathItem, Response}

  @operation_id_format ~r/^[a-z][A-Za-z0-9]*$/
  @http_methods [:get, :put, :post, :delete, :options, :head, :patch, :trace]

  @doc "Returns `:ok` or `{:error, problems}` with human-readable problems."
  @spec validate(OpenApi.t()) :: :ok | {:error, [String.t()]}
  def validate(%OpenApi{} = spec) do
    case operation_problems(spec) ++ example_problems(spec) do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  defp operation_problems(%OpenApi{paths: paths, tags: tags}) do
    declared_tags = MapSet.new(tags || [], & &1.name)
    operations = operations(paths)

    per_operation =
      Enum.flat_map(operations, fn {label, %Operation{} = operation} ->
        operation_id_problems(label, operation) ++
          summary_problems(label, operation) ++
          tag_problems(label, operation, declared_tags)
      end)

    duplicates =
      operations
      |> Enum.map(fn {_label, operation} -> operation.operationId end)
      |> Enum.frequencies()
      |> Enum.filter(fn {id, count} -> is_binary(id) and count > 1 end)
      |> Enum.map(fn {id, _count} -> "operationId #{inspect(id)} is used more than once" end)

    per_operation ++ duplicates
  end

  defp operations(paths) do
    for {path, %PathItem{} = item} <- Enum.sort(paths || %{}),
        method <- @http_methods,
        %Operation{} = operation <- [Map.get(item, method)] do
      {"#{method |> Atom.to_string() |> String.upcase()} #{path}", operation}
    end
  end

  defp operation_id_problems(label, %Operation{operationId: id}) do
    if is_binary(id) and Regex.match?(@operation_id_format, id) do
      []
    else
      ["#{label}: operationId must be camelCase (e.g. \"getHealth\"), got #{inspect(id)}"]
    end
  end

  defp summary_problems(label, %Operation{summary: summary}) do
    if is_binary(summary) and summary != "", do: [], else: ["#{label}: summary is missing"]
  end

  defp tag_problems(label, %Operation{tags: tags}, declared_tags) do
    case tags || [] do
      [] ->
        ["#{label}: at least one tag is required"]

      tags ->
        for tag <- tags, not MapSet.member?(declared_tags, tag) do
          "#{label}: tag #{inspect(tag)} is not declared in the spec's top-level tags"
        end
    end
  end

  defp example_problems(%OpenApi{components: %Components{} = components} = spec) do
    schema_problems =
      for {name, schema} <- Enum.sort(components.schemas || %{}),
          schema.example != nil,
          problem <- cast_problems(spec, schema, schema.example) do
        "components.schemas.#{name}.example: #{problem}"
      end

    response_problems =
      for {name, %Response{content: content}} <- Enum.sort(components.responses || %{}),
          {media_type, %MediaType{schema: schema, example: example}} <- Enum.sort(content || %{}),
          example != nil,
          problem <- cast_problems(spec, schema, example) do
        "components.responses.#{name}.content.#{media_type}.example: #{problem}"
      end

    schema_problems ++ response_problems
  end

  defp example_problems(%OpenApi{}), do: []

  # Examples are authored as Elixir terms; validate them in their JSON form,
  # exactly as clients will see them.
  defp cast_problems(spec, schema, example) do
    json_example = example |> Jason.encode!() |> Jason.decode!()

    case OpenApiSpex.cast_value(json_example, schema, spec) do
      {:ok, _value} -> []
      {:error, errors} -> Enum.map(errors, &to_string/1)
    end
  end
end
