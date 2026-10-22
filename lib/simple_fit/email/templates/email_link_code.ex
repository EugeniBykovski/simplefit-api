defmodule SimpleFit.Email.Templates.EmailLinkCode do
  @moduledoc """
  Email identity link code (SF-77, ADR 0024 and 0011).

  Sent when a signed-in user asks to add this address to their existing
  SimpleFit account. The code proves control of the mailbox; it only works
  in the account and session that asked, and never signs anyone in. This
  module only renders it.

  Not part of the Claude Design inventory (E01..E17): there is no artboard
  for it yet. It reuses the shared layout and the E17 composition, and says
  only what is true of the flow (ADR 0011 amendment, SF-77).

  Variables:

    * `:code` - 6 digits, shown as `318 064` (required)
    * `:expires_in_minutes` - the challenge lifetime, 1..1440 (required)
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{code: :string, expires_in_minutes: :integer}

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      minutes = Format.count(data.expires_in_minutes, "minute", "minutes")

      frame = %{
        subject: "Your SimpleFit email verification code: #{data.code}",
        preheader: "Confirm this address for an existing SimpleFit account.",
        tag: "VERIFY",
        footer: :security
      }

      blocks = [
        {:heading, "Confirm this email address"},
        {:paragraph,
         [
           "Someone signed in to an existing SimpleFit account asked to add this email address to it. Enter this code in that account to confirm the address is yours."
         ]},
        {:panel,
         [
           {:code, grouped(data.code), 44, :center},
           {:caption, "Expires in #{minutes}", :center}
         ]},
        {:paragraph,
         [{:strong, "Never share this code."}, " SimpleFit staff will never ask you for it."],
         :small},
        {:paragraph,
         [
           "Didn’t ask for this? You can ignore this email. Without the code, the address isn’t added to any account."
         ], :note}
      ]

      Layout.render(:email_link_code, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> validate_format(:code, ~r/\A\d{6}\z/)
    |> validate_number(:expires_in_minutes, greater_than: 0, less_than_or_equal_to: 1440)
  end

  defp grouped(<<first::binary-size(3), last::binary-size(3)>>), do: first <> " " <> last
end
