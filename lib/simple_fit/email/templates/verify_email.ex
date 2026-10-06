defmodule SimpleFit.Email.Templates.VerifyEmail do
  @moduledoc """
  E01 · Verify your email (`project/EmailVerify.dc.html`, Design Version 66,
  ADR 0011 and 0012).

  Email ownership verification for a new registration (SF-21). The 6-digit
  code and the "Verify email" link answer the same challenge; the link only
  verifies the address and never signs anyone in. This module only renders
  them.

  Variables:

    * `:code` - 6 digits, shown as `407 193` (required)
    * `:verify_url` - absolute https URL carrying the link token in its
      fragment, `<web app>/verify-email#token=...` (required)
    * `:expires_in_minutes` - the challenge lifetime, 1..1440 (required)
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{code: :string, verify_url: :string, expires_in_minutes: :integer}

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "Your SimpleFit verification code: #{data.code}",
        preheader: "Enter it where you’re signing up to verify your email.",
        tag: "VERIFY",
        footer: :security
      }

      blocks = [
        {:heading, "Verify your email"},
        {:paragraph,
         ["Enter this code where you’re signing up to finish creating your account."]},
        {:panel,
         [
           {:code, grouped(data.code), 44, :center},
           {:caption, "Expires in #{minutes(data.expires_in_minutes)}", :center}
         ]},
        {:paragraph, ["Or verify with this link:"], :small},
        {:button, "Verify email", data.verify_url, :dark},
        {:paragraph,
         [
           "The link and the code do the same thing: they verify this email address. Opening the link doesn’t sign you in."
         ], :note},
        {:paragraph, ["Didn’t try to sign up? You can ignore this email."], :note}
      ]

      Layout.render(:verify_email, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> validate_format(:code, ~r/\A\d{6}\z/)
    |> Input.validate_url(:verify_url)
    |> validate_number(:expires_in_minutes, greater_than: 0, less_than_or_equal_to: 1440)
  end

  defp grouped(<<first::binary-size(3), last::binary-size(3)>>), do: first <> " " <> last

  defp minutes(1), do: "1 minute"
  defp minutes(count), do: "#{count} minutes"
end
