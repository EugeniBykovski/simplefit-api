defmodule SimpleFit.Email.Templates.NewSignIn do
  @moduledoc """
  E10 · New sign-in alert (`project/EmailNewSignIn.dc.html`, ADR 0011).

  Tells a person about a new sign-in to their account. The trigger is
  deferred: deciding what counts as a new sign-in belongs to the future
  security work (SF-28 / security reconciliation). The email states only
  the sign-in time; it claims no device, browser, location or sign-in
  method, and promises no automatic sign-out or restriction.

  Required variables:

    * `:signed_in_at` - display time of the sign-in, with its time zone
      ("Oct 1, 21:14 CEST"), 1..40
    * `:security_url` - absolute https URL of the account security
      settings; presentation only (the destination is not part of SF-35)
  """

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{signed_in_at: :string, security_url: :string}

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "New sign-in to your SimpleFit account",
        preheader: "If this was you, no action is needed.",
        tag: "SECURITY",
        footer: :security
      }

      blocks = [
        {:eyebrow, "NEW SIGN-IN", :danger},
        {:heading, "New sign-in to your SimpleFit account"},
        {:paragraph, ["We noticed a new sign-in to your SimpleFit account."]},
        {:panel, [{:rows, [{"Time", data.signed_in_at}]}]},
        {:paragraph, [{:strong, "If this was you"}, ", no action is needed."]},
        {:paragraph,
         [{:strong, "If you don’t recognize this activity"}, ", secure your account."]},
        {:button, "Secure my account", data.security_url, :danger}
      ]

      Layout.render(:new_sign_in, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:signed_in_at, 40)
    |> Input.validate_url(:security_url)
  end
end
