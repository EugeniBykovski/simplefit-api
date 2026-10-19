defmodule SimpleFit.Legal.RegistryTest do
  @moduledoc """
  The legal document registry (SF-72; ADR 0022): the production registry is
  valid and empty, fixtures are refused there, every rule makes the whole
  registry invalid, and an invalid registry keeps Coach–Fighter sharing
  unavailable without stopping anything else.
  """

  # Not async: the registry and the sharing configuration are global.
  use SimpleFit.DataCase, async: false

  # Invalid registries are logged at :error by design (an operator must act).
  @moduletag :capture_log

  import SimpleFit.CoachingHelpers
  import SimpleFit.LegalHelpers

  alias Mix.Tasks.Legal.Hash
  alias SimpleFit.{Coaching, Legal}
  alias SimpleFit.Legal.Registry

  setup do
    configure_sharing()
    :ok
  end

  @disclosure %{
    document_id: "fighter-coach-disclosure",
    version: "fighter-coach-disclosure-test-1",
    scope: "basic_profile"
  }
  @rules %{document_id: "coach-data-rules", version: "coach-data-rules-test-1"}

  defp disclosure(extra),
    do:
      Map.merge(
        %{
          document_id: "fighter-coach-disclosure",
          version: "fighter-coach-disclosure-test-1",
          scope: "basic_profile"
        },
        extra
      )

  defp rules(extra \\ %{}),
    do: Map.merge(%{document_id: "coach-data-rules", version: "coach-data-rules-test-1"}, extra)

  test "the production registry is valid, empty and refuses test fixtures" do
    raw = File.read!("priv/legal/registry.json") |> Jason.decode!()
    assert raw == %{"documents" => []}

    assert use_production_registry!() == :ok
    assert Registry.valid?()
    assert Registry.published("fighter-coach-disclosure") == :error
    assert Registry.published("coach-data-rules") == :error

    # The flag alone never makes sharing ready.
    refute Coaching.sharing_ready?()

    assert use_registry!(Path.expand("test/support/legal"), false) ==
             {:invalid, :test_fixture_not_allowed}
  end

  test "the test fixtures are valid, published and clearly not legal texts" do
    assert Registry.valid?()
    assert {:ok, d} = Registry.published("fighter-coach-disclosure")
    assert d.test_only and d.approval_ref == "TEST-FIXTURE-NOT-APPROVED"
    assert d.languages["en"].full =~ "TEST FIXTURE ONLY"
    assert Coaching.sharing_ready?()
  end

  describe "every rule invalidates the whole registry" do
    for {name, specs, reason} <- [
          {"a tampered text", [Map.merge(@disclosure, %{tamper: true}), @rules],
           :content_hash_mismatch},
          {"two published versions",
           [
             @disclosure,
             Map.merge(@disclosure, %{version: "fighter-coach-disclosure-test-2"}),
             @rules
           ], :several_published},
          {"a malformed version",
           [Map.merge(@disclosure, %{version: "fighter-coach-disclosure-v1"}), @rules],
           :version_format},
          {"an unknown document", [Map.merge(@rules, %{document_id: "privacy-notice"})],
           :document_id},
          {"an unknown status", [Map.merge(@disclosure, %{status: "final"}), @rules], :status},
          {"an unknown scope", [Map.merge(@disclosure, %{scope: "full_profile"}), @rules],
           :scope},
          {"data rules with a scope", [Map.merge(@rules, %{scope: "basic_profile"})], :scope},
          {"a disclosure without a scope", [Map.merge(@disclosure, %{scope: nil}), @rules],
           :scope},
          {"an unknown language", [Map.merge(@disclosure, %{languages: ["en", "xx"]}), @rules],
           :language},
          {"an approved version without English",
           [Map.merge(@disclosure, %{languages: ["pl"]}), @rules], :reference_language},
          {"a withdrawn version without a notice",
           [
             Map.merge(@disclosure, %{
               status: "withdrawn",
               extra: %{"withdrawal_notice_ref" => nil}
             }),
             @rules
           ], :withdrawal_notice},
          {"a published version without approval",
           [Map.merge(@disclosure, %{extra: %{"approval_ref" => ""}}), @rules], :approval},
          {"an unknown field",
           [Map.merge(@disclosure, %{extra: %{"url" => "https://example.com"}}), @rules],
           :unknown_field}
        ] do
      test name do
        build_registry!(unquote(Macro.escape(specs)))
        assert {:invalid, unquote(reason)} = Registry.load()
        refute Registry.valid?()
        refute Coaching.sharing_ready?()
        assert Registry.get("coach-data-rules", "coach-data-rules-test-1") == :error
      end
    end

    test "a missing part file or registry file" do
      dir = build_registry!(standard_specs())

      File.rm!(
        Path.join([
          dir,
          "documents",
          "coach-data-rules",
          "coach-data-rules-test-1",
          "en",
          "checkbox.md"
        ])
      )

      assert {:invalid, :part_missing} = Registry.load()

      File.rm!(Path.join(dir, "registry.json"))
      assert {:invalid, :registry_missing} = Registry.load()
    end
  end

  test "an invalid registry never stops the rest of the application" do
    build_registry!([disclosure(%{tamper: true}), rules()])
    refute Registry.valid?()

    {:ok, user} = SimpleFit.Accounts.register_user(:google, "sf72-#{System.unique_integer()}")
    assert {:ok, _credentials} = SimpleFit.Accounts.create_session(user)

    assert {:error, :not_found} =
             Legal.public_document("fighter-coach-disclosure", :current, "en")
  end

  test "drafts and approved-but-unpublished versions are never acceptable or public" do
    build_registry!([
      disclosure(%{status: "draft"}),
      disclosure(%{version: "fighter-coach-disclosure-test-2", status: "approved"}),
      rules()
    ])

    assert Registry.valid?()

    set_sharing(
      disclosures: %{"fighter-coach-disclosure-test-2" => :basic_profile},
      current: "fighter-coach-disclosure-test-2"
    )

    refute Coaching.sharing_ready?()

    for v <- ["fighter-coach-disclosure-test-1", "fighter-coach-disclosure-test-2"] do
      assert Legal.public_document("fighter-coach-disclosure", v, "en") == {:error, :not_found}
    end
  end

  test "the content hash covers every part and their boundaries" do
    parts = %{"title" => "T", "summary" => "S", "checkbox" => "C", "full" => "F"}
    hash = Registry.content_sha256(parts)
    assert hash =~ ~r/\A[0-9a-f]{64}\z/
    assert Registry.content_sha256(parts) == hash

    for changed <- [
          %{parts | "full" => "F."},
          %{parts | "title" => "TS", "summary" => ""},
          %{parts | "checkbox" => "c"}
        ] do
      refute Registry.content_sha256(changed) == hash
    end
  end

  test "mix legal.hash prints the registry hash of a variant" do
    dir = Path.expand("test/support/legal/documents/coach-data-rules/coach-data-rules-test-1/en")
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Hash.run([dir])
    assert_received {:mix_shell, :info, [hash]}

    {:ok, version} = Registry.get("coach-data-rules", "coach-data-rules-test-1")
    assert hash == version.languages["en"].content_sha256
  end
end
