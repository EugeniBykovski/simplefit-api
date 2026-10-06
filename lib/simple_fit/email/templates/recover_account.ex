defmodule SimpleFit.Email.Templates.RecoverAccount do
  @moduledoc """
  E11 · Recover your account (`project/EmailRecover.dc.html`, ADR 0011).

  Sent by account recovery (expected SF-28) with the short-lived recovery
  link it issues. This module only renders it: no code, no passkey step.

  Variables (all required):

    * `:recovery_url` - absolute https URL carrying the credential
    * `:expires_in_minutes` - the link lifetime to display, 1..1440;
      presentation data, the credential lifetime itself belongs to SF-28
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{recovery_url: :string, expires_in_minutes: :integer}

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      minutes = Format.count(data.expires_in_minutes, "minute", "minutes")

      frame = %{
        subject: "Recover your SimpleFit account",
        preheader: "Use this link within #{minutes}.",
        tag: "RECOVERY",
        footer: :security
      }

      blocks = [
        {:heading, "Recover your account"},
        {:paragraph,
         [
           "We received a request to recover access to your SimpleFit account. This link expires in #{minutes}."
         ]},
        {:button, "Recover my account", data.recovery_url, :dark},
        {:paragraph,
         [
           "Didn’t ask for this? Someone may have entered your email by mistake. You can ignore this message."
         ], :note}
      ]

      Layout.render(:recover_account, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_url(:recovery_url)
    |> validate_number(:expires_in_minutes, greater_than: 0, less_than_or_equal_to: 1440)
  end
end
