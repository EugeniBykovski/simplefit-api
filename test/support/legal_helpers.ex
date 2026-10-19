defmodule SimpleFit.LegalHelpers do
  @moduledoc """
  Test helpers for the legal document registry (ADR 0022): switch to the
  production registry (no approved document) or to a temporary registry
  built from version specs, and restore the test registry afterwards. The
  registry is global state: tests that switch it are not async.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SimpleFit.Legal.Registry

  @doc "Uses the registry at `path` for this test (fixtures allowed or not)."
  def use_registry!(path, allow_test_fixtures \\ false) do
    previous = Application.get_env(:simple_fit, SimpleFit.Legal)

    on_exit(fn ->
      Application.put_env(:simple_fit, SimpleFit.Legal, previous)
      Registry.load()
    end)

    Application.put_env(:simple_fit, SimpleFit.Legal,
      registry_path: path,
      allow_test_fixtures: allow_test_fixtures
    )

    Registry.load()
  end

  @doc "Uses the production registry (`priv/legal`)."
  def use_production_registry!, do: use_registry!(Path.expand("priv/legal"))

  @doc """
  Builds a temporary registry from `specs` and uses it. Each spec is a map
  with `:document_id`, `:version`, `:status` and optionally `:scope`,
  `:languages` (default `["en"]`), `:text` (a marker in every part),
  `:tamper` (write different text than hashed) and raw `:extra` fields.
  Test-only versions (`-test-`) are marked `test_only`.
  """
  def build_registry!(specs) do
    dir = Path.join(System.tmp_dir!(), "sf72-registry-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    entries = Enum.map(specs, &write_version!(dir, &1))
    File.write!(Path.join(dir, "registry.json"), Jason.encode!(%{"documents" => entries}))
    use_registry!(dir, true)
    dir
  end

  defp write_version!(dir, spec) do
    languages = Map.get(spec, :languages, ["en"])
    marker = Map.get(spec, :text, spec.version)

    hashes =
      Map.new(languages, fn language ->
        parts = %{
          "title" => "TEST FIXTURE #{marker} #{language}",
          "summary" => "TEST FIXTURE summary #{marker} #{language}",
          "checkbox" => "TEST FIXTURE checkbox #{marker} #{language}",
          "full" => "# TEST FIXTURE\n\n#{marker} #{language}\n"
        }

        variant = Path.join([dir, "documents", spec.document_id, spec.version, language])
        File.mkdir_p!(variant)
        written = if spec[:tamper], do: Map.put(parts, "full", "tampered"), else: parts
        for {part, text} <- written, do: File.write!(Path.join(variant, part <> ".md"), text)
        {language, %{"content_sha256" => Registry.content_sha256(parts)}}
      end)

    status = Map.get(spec, :status, "published")

    %{
      "document_id" => spec.document_id,
      "version" => spec.version,
      "status" => status,
      "test_only" => String.contains?(spec.version, "-test-"),
      "languages" => hashes
    }
    |> maybe_put("scope", spec[:scope])
    |> then(fn entry ->
      if status == "draft",
        do: entry,
        else:
          Map.merge(entry, %{
            "approval_ref" => "TEST-FIXTURE-NOT-APPROVED",
            "approved_by" => ["test fixture"],
            "effective_at" => "2026-01-01T00:00:00Z"
          })
    end)
    |> then(fn entry ->
      if status in ~w(published superseded withdrawn),
        do: Map.put(entry, "published_at", "2026-01-01T00:00:00Z"),
        else: entry
    end)
    |> then(fn entry ->
      if status == "withdrawn",
        do: Map.put(entry, "withdrawal_notice_ref", "TEST-NOTICE"),
        else: entry
    end)
    |> Map.merge(Map.get(spec, :extra, %{}))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "The standard test pair (disclosure and data rules), plus `more`."
  def standard_specs(more \\ []) do
    [
      %{
        document_id: "fighter-coach-disclosure",
        version: "fighter-coach-disclosure-test-1",
        scope: "basic_profile",
        languages: ["en", "pl"]
      },
      %{
        document_id: "coach-data-rules",
        version: "coach-data-rules-test-1",
        languages: ["en", "pl"]
      }
    ] ++ more
  end
end
