defmodule SimpleFit.Email.Templates.DataExportReady do
  @moduledoc """
  E16 · Data export ready (`project/EmailExportReady.dc.html`, ADR 0011).

  Sent when a requested data export is ready. The trigger is deferred: no
  export generation or storage exists. The renderer only accepts
  presentation data; it generates, stores and signs nothing.

  Variables (all required; the export domain owns generation, storage,
  authorization and the real expiry policy):

    * `:requested_on` - `Date` the export was requested
    * `:file_name` - 1..120
    * `:size` - display ("842 MB"), 1..20
    * `:includes` - display ("Trainings, Board, messages, videos"), 1..120
    * `:formats` - display ("JSON + CSV + MP4"), 1..60
    * `:expires_on` - displayed `Date` the download expires, after
      `:requested_on`
    * `:available_days` - displayed availability in the preheader
      ("Available for 7 days."), 1..90
    * `:download_url` - absolute https URL; the email does not decide how
      the download authenticates or authorizes
    * `:security_url` - absolute https URL of the account security
      settings; presentation only
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    requested_on: :date,
    file_name: :string,
    size: :string,
    includes: :string,
    formats: :string,
    expires_on: :date,
    available_days: :integer,
    download_url: :string,
    security_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "Your SimpleFit data is ready to download",
        preheader: "Available for #{Format.count(data.available_days, "day", "days")}.",
        tag: "YOUR DATA",
        footer: :security
      }

      blocks = [
        {:heading, "Your data is ready."},
        {:paragraph,
         [
           "Here’s everything you’ve created on SimpleFit, as you requested on #{Format.short_date(data.requested_on)}."
         ]},
        {:panel,
         [
           {:rows,
            [
              {"File", data.file_name},
              {"Size", data.size},
              {"Includes", data.includes},
              {"Formats", data.formats},
              {"Expires", Format.short_date(data.expires_on)}
            ]}
         ]},
        {:button, "Download my data", data.download_url, :dark},
        {:paragraph,
         [
           "Your export contains personal data — keep the file somewhere safe. Didn’t request this? ",
           {:link, "Secure your account", data.security_url, :danger},
           "."
         ], :note}
      ]

      Layout.render(:data_export_ready, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:file_name, 120)
    |> Input.validate_line(:size, 20)
    |> Input.validate_line(:includes, 120)
    |> Input.validate_line(:formats, 60)
    |> validate_number(:available_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 90)
    |> Input.validate_url(:download_url)
    |> Input.validate_url(:security_url)
    |> validate_change(:expires_on, fn :expires_on, expires_on ->
      requested_on = get_field(changeset, :requested_on)

      if requested_on && Date.compare(expires_on, requested_on) != :gt,
        do: [expires_on: {"must be after the request", validation: :number}],
        else: []
    end)
  end
end
