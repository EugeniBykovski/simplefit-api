defmodule SimpleFit.Legal.Evidence do
  @moduledoc """
  Evidence that a person accepted or acknowledged an exact legal text
  (ADR 0022; SF-71 L-08): which document, version and language, the hash of
  the text they were shown, who and when, and for an acceptance the
  invitation and relationship it belongs to. Nothing else: no names,
  addresses, notes, IP or device data.

  Append-only and independent: no foreign key, so deleting an invitation, a
  relationship, a profile or an account never deletes it (the identifiers
  remain as plain values). The database rejects any update; deletion is
  reserved for the retention and erasure work that will own it (SF-71 T-2,
  T-3) once counsel approves the periods. Written only by `SimpleFit.Legal`,
  inside the transaction of the action it proves; there is no endpoint.
  """

  use Ecto.Schema

  @type kind :: :fighter_disclosure_acceptance | :coach_data_rules_acknowledgement

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          kind: kind() | nil,
          subject_user_id: Ecto.UUID.t() | nil,
          counterparty_user_id: Ecto.UUID.t() | nil,
          invitation_id: Ecto.UUID.t() | nil,
          relationship_id: Ecto.UUID.t() | nil,
          document_id: String.t() | nil,
          document_version: String.t() | nil,
          document_language: String.t() | nil,
          content_sha256: String.t() | nil,
          recorded_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "legal_evidence" do
    field :kind, Ecto.Enum,
      values: [:fighter_disclosure_acceptance, :coach_data_rules_acknowledgement]

    field :subject_user_id, :binary_id
    field :counterparty_user_id, :binary_id
    field :invitation_id, :binary_id
    field :relationship_id, :binary_id
    field :document_id, :string
    field :document_version, :string
    field :document_language, :string
    field :content_sha256, :string
    field :recorded_at, :utc_datetime_usec
  end
end
