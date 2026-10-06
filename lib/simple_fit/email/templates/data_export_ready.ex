defmodule SimpleFit.Email.Templates.DataExportReady do
  @moduledoc """
  E16 · Data export ready (`EmailExportReady.dc.html`, ADR 0011).

  Sent when a requested data export is ready. The trigger is deferred: no
  export generation or storage exists. The renderer only accepts
  presentation data; it generates, stores and signs nothing.

  Variables (all required):

    * `:requested_on` - `Date` the export was requested
    * `:file_name` - 1..120
    * `:size` - display ("842 MB"), 1..20
    * `:includes` - display ("Trainings, Board, messages, videos"), 1..120
    * `:formats` - display ("JSON + CSV + MP4"), 1..60
    * `:expires_on` - `Date` the download expires, after `:requested_on`
    * `:download_url` - absolute https URL; per the design, downloading
      asks the person to sign in with their passkey
    * `:security_url` - absolute https URL of the account security settings

  The preheader's "Available for 7 days" is the design's fixed copy; the
  sender must give the download that lifetime.
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
    download_url: :string,
    security_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "Your SimpleFit data is ready to download",
        preheader: "Available for 7 days. You’ll need to sign in to download.",
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
           "For your security, downloading asks you to sign in with your passkey. Didn’t request this? ",
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
