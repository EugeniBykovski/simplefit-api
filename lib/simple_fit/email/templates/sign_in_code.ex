defmodule SimpleFit.Email.Templates.SignInCode do
  @moduledoc """
  E17 · Sign-in code (`project/EmailSignInCode.dc.html`, Design Version 66,
  ADR 0011 and 0012).

  The email sign-in code of passwordless authentication (SF-21). Code only:
  there is no sign-in link. This module only renders it.

  Variables:

    * `:code` - 6 digits, shown as `528 461` (required)
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
        subject: "Your SimpleFit sign-in code: #{data.code}",
        preheader: "It expires in #{minutes}. Never share it.",
        tag: "SIGN IN",
        footer: :security
      }

      blocks = [
        {:heading, "Your sign-in code"},
        {:paragraph, ["Enter this code where you asked to sign in to SimpleFit."]},
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
           "Didn’t try to sign in? You can ignore this email — someone may have typed your address by mistake."
         ], :note}
      ]

      Layout.render(:sign_in_code, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> validate_format(:code, ~r/\A\d{6}\z/)
    |> validate_number(:expires_in_minutes, greater_than: 0, less_than_or_equal_to: 1440)
  end

  defp grouped(<<first::binary-size(3), last::binary-size(3)>>), do: first <> " " <> last
end
