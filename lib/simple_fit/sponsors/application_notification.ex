defmodule SimpleFit.Sponsors.ApplicationNotification do
  @moduledoc """
  One sponsor application notification intent (SF-114): what was to be sent, to
  whom (`applicant` or `contact`, never an address), whether it was queued (with
  its Oban job) or suppressed and why. The dedupe key makes each intent once-only.
  Append-only.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "sponsor_application_notifications" do
    field :application_id, :binary_id

    field :kind, Ecto.Enum,
      values: [
        :application_received,
        :application_resubmitted,
        :changes_requested,
        :contact_verification_code,
        :application_approved,
        :application_rejected
      ]

    field :recipient, Ecto.Enum, values: [:applicant, :contact]
    field :status, Ecto.Enum, values: [:queued, :suppressed]
    field :suppressed_reason, :string
    field :dedupe_key, :string
    field :oban_job_id, :integer

    timestamps()
  end
end
