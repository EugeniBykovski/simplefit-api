defmodule SimpleFit.Email.Templates.VerifyEmail do
  @moduledoc """
  E01 · Verify your email (`project/EmailVerify.dc.html`, ADR 0011).

  Sent by email sign-up (SF-21) with the one-time code and the one-tap
  verification link that SF-21 issues. This module only renders them.

  Variables:

    * `:code` - 6 digits, shown as `407 193` (required)
    * `:verify_url` - absolute https URL carrying the credential (required)
    * `:expires_in_minutes` - 1..1440 (required)
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{code: :string, verify_url: :string, expires_in_minutes: :integer}

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "Your SimpleFit code: #{data.code}",
        preheader: "Enter it in the app to confirm your email.",
        tag: "VERIFY",
        footer: :security
      }

      blocks = [
        {:heading, "Confirm your email"},
        {:paragraph, ["Enter this code in the app to finish creating your account."]},
        {:panel,
         [
           {:code, grouped(data.code), 44, :center},
           {:caption, "Expires in #{minutes(data.expires_in_minutes)}", :center}
         ]},
        {:paragraph, ["Or confirm with one tap on this phone:"], :small},
        {:button, "Verify email", data.verify_url, :dark},
        {:paragraph,
         ["Didn’t try to sign up? Ignore this email — no account is created without the code."],
         :note}
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
