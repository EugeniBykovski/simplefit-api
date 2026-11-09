defmodule SimpleFit.Sponsors.ApplicationContactCode do
  @moduledoc """
  A one-time code sent to an application's contact email (SF-114). Only a keyed
  verifier of the code and a keyed digest of the address are stored; the code is
  valid for that address only, expires, and allows five attempts.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "sponsor_application_contact_codes" do
    field :application_id, :binary_id
    field :email_digest, :binary, redact: true
    field :code_verifier, :binary, redact: true
    field :attempts, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec

    timestamps()
  end
end
