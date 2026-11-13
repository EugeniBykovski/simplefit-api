defmodule SimpleFit.Email.Templates.PasswordResetCode do
  @moduledoc """
  Password code (SF-157, ADR 0012 amendment and ADR 0011).

  Sent when someone asks to set or reset the password of the account that has
  this email address. The code proves control of the mailbox; entering it with a
  new password replaces any previous password and signs the account out
  everywhere. It never signs anyone in. This module only renders it.

  Not part of the Claude Design inventory (E01..E17): there is no artboard for it
  yet. It reuses the shared layout and the E17 composition, and says only what is
  true of the flow.

  Variables:

    * `:code` - 6 digits, shown as `604 218` (required)
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
        subject: "Your SimpleFit password code: #{data.code}",
        preheader: "Set a new password for your SimpleFit account.",
        tag: "PASSWORD",
        footer: :security
      }

      blocks = [
        {:heading, "Set your password"},
        {:paragraph,
         [
           "Someone asked to set a new password for the SimpleFit account with this email address. Enter this code with your new password to continue. Your account will be signed out on every device."
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
           "Didn’t ask for this? You can ignore this email. Without the code, your password doesn’t change."
         ], :note}
      ]

      Layout.render(:password_reset_code, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> validate_format(:code, ~r/\A\d{6}\z/)
    |> validate_number(:expires_in_minutes, greater_than: 0, less_than_or_equal_to: 1440)
  end

  defp grouped(<<first::binary-size(3), last::binary-size(3)>>), do: first <> " " <> last
end
