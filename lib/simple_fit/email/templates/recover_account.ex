defmodule SimpleFit.Email.Templates.RecoverAccount do
  @moduledoc """
  E11 · Recover your account (`EmailRecover.dc.html`, ADR 0011).

  Sent by account recovery (expected SF-28) with the one-time recovery link
  and code it issues. This module only renders them.

  Variables:

    * `:recovery_url` - absolute https URL carrying the credential (required)
    * `:code` - uppercase letters and digits in dash-separated groups,
      4..16 characters, e.g. `K7Q-2MX` (required)
    * `:expires_in_minutes` - 1..1440 (required)
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{recovery_url: :string, code: :string, expires_in_minutes: :integer}

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      minutes = minutes(data.expires_in_minutes)

      frame = %{
        subject: "Recover your SimpleFit account",
        preheader: "Use this link within #{minutes}.",
        tag: "RECOVERY",
        footer: :security
      }

      blocks = [
        {:heading, "Recover your account"},
        {:paragraph,
         ["You asked to sign in without your passkey — for example after getting a new phone."]},
        {:button, "Sign in and add a new passkey", data.recovery_url, :dark},
        {:panel,
         [
           {:label, "OR ENTER THIS CODE"},
           {:code, data.code, 30, :left},
           {:caption, "Valid for #{minutes} · works once", :left}
         ]},
        {:paragraph,
         [
           "Didn’t ask for this? Someone may know your email. Ignore this message — your account stays locked without the code."
         ], :note}
      ]

      Layout.render(:recover_account, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_url(:recovery_url)
    |> validate_format(:code, ~r/\A[A-Z0-9]+(-[A-Z0-9]+)*\z/)
    |> validate_length(:code, min: 4, max: 16)
    |> validate_number(:expires_in_minutes, greater_than: 0, less_than_or_equal_to: 1440)
  end

  defp minutes(1), do: "1 minute"
  defp minutes(count), do: "#{count} minutes"
end
