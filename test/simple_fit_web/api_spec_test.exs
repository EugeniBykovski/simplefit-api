defmodule SimpleFitWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  alias SimpleFitWeb.ApiSpec
  alias SimpleFitWeb.ApiSpec.Validation

  setup_all do
    %{spec: ApiSpec.spec()}
  end

  test "passes contract validation (operation ids, tags, examples)", %{spec: spec} do
    assert Validation.validate(spec) == :ok
  end

  test "declares document metadata", %{spec: spec} do
    assert spec.openapi =~ ~r/^3\./
    assert spec.info.title == "SimpleFit API"
    assert spec.info.version == Mix.Project.config()[:version]
    assert [%{url: "/"}] = spec.servers
  end

  test "documents GET /api/health", %{spec: spec} do
    operation = spec.paths["/api/health"].get

    assert operation.operationId == "getHealth"
    assert operation.tags == ["System"]
    assert Map.has_key?(operation.responses, 200)
  end

  test "provides a reusable error response for every error code", %{spec: spec} do
    expected =
      MapSet.new(SimpleFitWeb.APIError.codes(), &Macro.camelize/1)

    assert MapSet.new(Map.keys(spec.components.responses)) == expected
  end

  test "reserves a bearer security scheme", %{spec: spec} do
    assert %{type: "http", scheme: "bearer"} = spec.components.securitySchemes["bearerAuth"]
  end

  test "generation is deterministic" do
    assert ApiSpec.to_json() == ApiSpec.to_json()
  end

  test "the committed artifact matches the spec generated from code" do
    assert File.read!(ApiSpec.artifact_path()) == ApiSpec.to_json(),
           "openapi/simplefit.api.json is stale; run `mix openapi.gen` and commit the result"
  end

  test "validation reports broken operations and examples", %{spec: spec} do
    operation = %{spec.paths["/api/health"].get | operationId: "Bad.Id", tags: ["Unknown"]}
    broken_schema = %{spec.components.schemas["HealthResponse"] | example: %{"status" => 1}}

    broken = %{
      spec
      | paths: %{"/api/health" => %{spec.paths["/api/health"] | get: operation}},
        components: %{
          spec.components
          | schemas: Map.put(spec.components.schemas, "HealthResponse", broken_schema)
        }
    }

    assert {:error, problems} = Validation.validate(broken)
    assert Enum.any?(problems, &(&1 =~ "operationId must be camelCase"))
    assert Enum.any?(problems, &(&1 =~ ~s(tag "Unknown" is not declared)))
    assert Enum.any?(problems, &(&1 =~ "components.schemas.HealthResponse.example"))
  end
end
