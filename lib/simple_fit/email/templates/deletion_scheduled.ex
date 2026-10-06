defmodule SimpleFit.Email.Templates.DeletionScheduled do
  @moduledoc """
  E14 · Deletion scheduled (`project/EmailDeleteScheduled.dc.html`, ADR 0011).

  Sent by the account-deletion lifecycle (expected SF-28) when a user asks
  to delete their account.

  Required variables:

    * `:requested_on` - `Date` the request was received
    * `:deletion_on` - `Date` the account will be deleted, after the request
    * `:restore_url` - absolute https URL to restore the account; the
      restore workflow belongs to the deletion lifecycle
    * `:data_download_url` - absolute https URL to download the data

  Optional variables:

    * `:retained_gym_payments` - boolean, default `false`: the person has
      gym payment records kept anonymised by law, shown as the "We keep ·
      anonymised" section; omitted otherwise

  The deleted and kept lists are the design's fixed policy copy.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{
    requested_on: :date,
    deletion_on: :date,
    restore_url: :string,
    data_download_url: :string,
    retained_gym_payments: :boolean
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1, [:retained_gym_payments]) do
      retained? = Map.get(data, :retained_gym_payments, false)
      deletion_on = short_date(data.deletion_on)

      frame = %{
        subject: "Your account will be deleted on #{deletion_on}",
        preheader: "Changed your mind? You can restore it before then.",
        tag: "ACCOUNT",
        footer: :security
      }

      blocks = [
        {:heading, "Your account will be deleted on #{deletion_on}."},
        {:paragraph,
         [
           "We received your request on #{short_date(data.requested_on)} and scheduled your account for deletion. You can restore it any time before then."
         ]},
        {:button, "Restore my account", data.restore_url, :olive},
        {:panel,
         [
           {:label, "ON #{String.upcase(deletion_on)} WE DELETE"},
           {:bullets,
            [
              "Profile, trainings, Board, achievements",
              "Friends, comments, videos and notes about you"
            ], :olive},
           if(retained?, do: {:label, "WE KEEP · ANONYMISED"}),
           if(retained?,
             do:
               {:bullets,
                ["Gym payments and attendance — 5 years, required by Polish accounting law"],
                :muted}
           )
         ]},
        {:paragraph,
         [
           "Want a copy first? ",
           {:link, "Download your data", data.data_download_url},
           " — the link works until #{deletion_on}."
         ], :small}
      ]

      Layout.render(:deletion_scheduled, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_url(:restore_url)
    |> Input.validate_url(:data_download_url)
    |> validate_change(:deletion_on, fn :deletion_on, deletion_on ->
      requested_on = get_field(changeset, :requested_on)

      if requested_on && Date.compare(deletion_on, requested_on) != :gt,
        do: [deletion_on: {"must be after the request", validation: :number}],
        else: []
    end)
  end

  # "Nov 3", as in the design (English, no year).
  defp short_date(date), do: Calendar.strftime(date, "%b %-d")
end
