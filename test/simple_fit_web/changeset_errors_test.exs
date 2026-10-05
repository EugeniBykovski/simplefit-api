defmodule SimpleFitWeb.ChangesetErrorsTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset
  import OpenApiSpex.TestAssertions

  alias SimpleFitWeb.{ApiSpec, ChangesetErrors}

  defmodule Address do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :city, :string
    end

    def changeset(address, params) do
      address |> cast(params, [:city]) |> validate_required([:city])
    end
  end

  defmodule Profile do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :email, :string
      field :name, :string
      field :age, :integer
      field :stance, :string
      embeds_one :address, Address
      embeds_many :rounds, Address
    end
  end

  defp profile(params, validate) do
    %Profile{}
    |> cast(params, [:email, :name, :age, :stance])
    |> validate.()
  end

  defp details(changeset) do
    details = ChangesetErrors.details(changeset)
    # Every result is valid against the published schema, in its JSON form.
    json = details |> Jason.encode!() |> Jason.decode!()
    assert_schema(json, "ValidationErrorDetails", ApiSpec.spec())
    json
  end

  test "keeps the SF-2 fields contract and adds aligned machine-readable codes" do
    changeset =
      profile(%{"email" => "nope"}, fn changeset ->
        changeset
        |> validate_required([:email, :name])
        |> validate_format(:email, ~r/@/)
        |> validate_length(:email, min: 6)
      end)

    assert %{"fields" => fields, "field_codes" => codes} = details(changeset)

    assert fields["name"] == ["can't be blank"]
    assert codes["name"] == ["required"]

    # Several errors on one field: same entries, same order, in both maps.
    assert Enum.zip(codes["email"], fields["email"]) == [
             {"invalid_format", "has invalid format"},
             {"too_short", "should be at least 6 character(s)"}
           ]

    assert Map.keys(fields) == Map.keys(codes)
  end

  test "derives codes from Ecto's validation metadata, not from messages" do
    changeset =
      profile(%{"name" => String.duplicate("x", 30), "age" => 9, "stance" => "boxer"}, fn cs ->
        cs
        |> validate_length(:name, max: 20, message: "custom wording")
        |> validate_number(:age, greater_than: 10)
        |> validate_inclusion(:stance, ["orthodox", "southpaw"])
      end)

    assert %{"field_codes" => codes, "fields" => fields} = details(changeset)

    assert codes == %{
             "name" => ["too_long"],
             "age" => ["out_of_range"],
             "stance" => ["invalid_choice"]
           }

    # The message can be anything; the code does not depend on it.
    assert fields["name"] == ["custom wording"]
  end

  test "maps type, length, acceptance, confirmation and constraint errors" do
    changeset =
      %Profile{}
      |> cast(%{"age" => "not a number"}, [:age])
      |> validate_length(:email, is: 5)
      |> add_error(:email, "has already been taken", constraint: :unique, constraint_name: "x")
      |> add_error(:name, "does not exist", constraint: :foreign, constraint_name: "y")
      |> add_error(:stance, "must be accepted", validation: :acceptance)
      |> add_error(:stance, "does not match", validation: :confirmation)
      |> add_error(:stance, "is odd")

    assert details(changeset)["field_codes"] == %{
             "age" => ["invalid_type"],
             "email" => ["already_exists"],
             "name" => ["does_not_exist"],
             # In the order the validations ran.
             "stance" => ["must_be_accepted", "does_not_match", "invalid"]
           }
  end

  test "interpolates message placeholders" do
    changeset = profile(%{"name" => "ab"}, &validate_length(&1, :name, min: 3))

    assert details(changeset)["fields"]["name"] == ["should be at least 3 character(s)"]
  end

  test "flattens nested changesets into dotted paths" do
    changeset =
      %Profile{}
      |> cast(%{"address" => %{}, "rounds" => [%{"city" => "Warsaw"}, %{}]}, [])
      |> cast_embed(:address, with: &Address.changeset/2)
      |> cast_embed(:rounds, with: &Address.changeset/2)

    assert details(changeset) == %{
             "fields" => %{
               "address.city" => ["can't be blank"],
               "rounds.1.city" => ["can't be blank"]
             },
             "field_codes" => %{
               "address.city" => ["required"],
               "rounds.1.city" => ["required"]
             }
           }
  end

  test "never exposes submitted values" do
    changeset =
      profile(%{"email" => "secret-value@"}, &validate_format(&1, :email, ~r/\A[^@]+@[^@]+\z/))

    refute Jason.encode!(ChangesetErrors.details(changeset)) =~ "secret-value"
  end

  test "publishes the reason codes in the OpenAPI schema" do
    schema = ApiSpec.spec().components.schemas["ValidationErrorDetails"]

    assert schema.properties.field_codes.additionalProperties.items.enum ==
             ChangesetErrors.reason_codes()
  end
end
