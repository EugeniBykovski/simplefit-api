defmodule SimpleFit.Repo.Migrations.AddBillingOversightIndexes do
  @moduledoc """
  SF-127: indexes for the operator billing projections, which read across gyms where
  every existing index starts with the gym: subscriptions newest first, a
  subscription's latest checkout (its environment), invoices of one mode newest first,
  and paid invoices of one mode by payment time (the collected sums). No data changes.
  """

  use Ecto.Migration

  def change do
    create index(:gym_saas_subscriptions, [:requested_at, :id])
    create index(:stripe_checkouts, [:subscription_id, :inserted_at])
    create index(:stripe_invoices, [:mode, :provider_created_at, :id])

    create index(:stripe_invoices, [:mode, :paid_at],
             where: "status = 'paid'",
             name: :stripe_invoices_paid_index
           )
  end
end
