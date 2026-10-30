defmodule SimpleFit.Email.Templates.MemberInvite do
  @moduledoc """
  E07 · Member invitation from a gym (`project/EmailMemberInvite.dc.html`,
  ADR 0011), with the approved copy correction C15 / R10 (SF-82 12): no
  membership plan, payment method or "the gym shared your name, email and
  plan"; the privacy line says the gym used the email address to invite; the
  link is `<web app>/invite/gym#token=…`.

  Sent when a gym's owner, a manager or the front desk invites an email
  address to become a member (SF-95, `SimpleFit.Gyms`). The renderer only
  accepts presentation data; it creates no invitation and no token. Interim
  copy: C15's "book classes and check in" is left out until those domains
  exist (no ability is promised before it ships), and there is no opt-out
  link (no opt-out flow exists; ignoring the email lets the invitation
  expire, as the footer says).

  Variables (required unless marked optional):

    * `:member_name` - optional, the invitee's first name, 1..80 (SF-95
      sends none: an invitation is addressed to an email, not a person)
    * `:gym_name` - 1..80
    * `:home_location` - optional, 1..60
    * `:accept_url` - absolute https URL; any credential in it belongs to
      the sending domain
    * `:expires_on` - `Date` the invitation expires
  """

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    member_name: :string,
    gym_name: :string,
    home_location: :string,
    accept_url: :string,
    expires_on: :date
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <-
           Input.validate(attrs, @types, &checks/1, [:member_name, :home_location]) do
      frame = %{
        subject: "#{data.gym_name} invited you to join on SimpleFit",
        preheader: "Accept with this email address — nothing changes until you do.",
        tag: "YOUR GYM",
        footer: :invitation
      }

      blocks = [
        {:heading, greeting(data)},
        {:paragraph,
         [
           "#{data.gym_name} invited you to join on SimpleFit. Accepting makes you a member of the gym on your own SimpleFit account."
         ]},
        {:panel,
         [
           {:rows,
            [
              {"Gym", data.gym_name},
              data[:home_location] && {"Home location", data.home_location},
              {"Invitation expires", Format.long_date(data.expires_on)}
            ]}
         ]},
        {:button, "Accept invitation", data.accept_url, :dark},
        {:panel,
         [
           {:paragraph,
            [
              {:strong, "Your privacy:"},
              " the gym used your email address to invite you. Your training data stays private."
            ], :note}
         ], :quiet}
      ]

      Layout.render(:member_invite, frame, blocks)
    end
  end

  defp greeting(%{member_name: name} = data),
    do: "Hi #{name}, you’re invited to join #{data.gym_name}."

  defp greeting(data), do: "You’re invited to join #{data.gym_name}."

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:member_name, 80)
    |> Input.validate_line(:gym_name, 80)
    |> Input.validate_line(:home_location, 60)
    |> Input.validate_url(:accept_url)
  end
end
