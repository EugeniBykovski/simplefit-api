defmodule SimpleFit.Billing.Stripe.WebhookEvent do
  @moduledoc """
  The webhook inbox (SF-102): one row per signature-verified Stripe event,
  unique per mode; ids and type only, never the payload (reconciliation
  re-fetches the authoritative object). `received` until processed,
  `ignored` (not ours or not handled) or `failed`; `outcome` is a code.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "stripe_webhook_events" do
    field :mode, Ecto.Enum, values: [:test, :live]
    field :stripe_event_id, :string
    field :event_type, :string
    field :object_type, :string
    field :object_id, :string
    field :event_created_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: [:received, :processed, :ignored, :failed]
    field :outcome, :string
    field :attempts, :integer, default: 0
    field :processed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
