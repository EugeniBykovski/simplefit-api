defmodule SimpleFit.Email.Templates.DeletionScheduled do
  @moduledoc """
  E14 · Deletion scheduled (`EmailDeleteScheduled.dc.html`, ADR 0011).

  Sent by the account-deletion lifecycle (expected SF-28) when a user asks
  to delete their account.

  Variables:

    * `:requested_on` - `Date` the request was received (required)
    * `:deletion_on` - `Date` the account will be deleted (required)
    * `:restore_url` - absolute https URL to restore the account (required)
    * `:data_download_url` - absolute https URL to download the data (required)

  The lists of deleted and kept data are the design's fixed policy copy.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{
    requested_on: :date,
    deletion_on: :date,
    restore_url: :string,
    data_download_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      deletion_on = short_date(data.deletion_on)

      frame = %{
        subject: "Your account will be deleted on #{deletion_on}",
        preheader: "Changed your mind? Restore it with one tap before then.",
        tag: "ACCOUNT",
        footer: :security
      }

      blocks = [
        {:heading, "Your account will be deleted on #{deletion_on}."},
        {:paragraph,
         [
           "We received your request on #{short_date(data.requested_on)}. Your profile is hidden now and you’ve been signed out on other devices."
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
           {:label, "WE KEEP · ANONYMISED"},
           {:bullets,
            ["Gym payments and attendance — 5 years, required by Polish accounting law"], :muted}
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
