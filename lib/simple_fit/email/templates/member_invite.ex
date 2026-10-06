defmodule SimpleFit.Email.Templates.MemberInvite do
  @moduledoc """
  E07 · Member invite from gym (`EmailMemberInvite.dc.html`, ADR 0011).

  Sent when a gym moves its existing members to SimpleFit. The trigger is
  deferred: no gym membership or member-import domain exists yet. The
  renderer only accepts presentation data; it creates no invitation, token
  or opt-out flow.

  Variables (all required):

    * `:member_name` - 1..80
    * `:gym_name` - 1..80
    * `:plan` - membership plan ("Unlimited"), 1..60
    * `:active_until` - `Date` the membership is active until
    * `:home_location` - 1..60
    * `:claim_url` - absolute https URL to claim the membership
    * `:opt_out_url` - absolute https URL of the opt-out, supplied by the
      sender (the design says opting out deletes the invite; that flow is
      the sender's)

  The benefits list and privacy note are the design's fixed copy.
  """

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    member_name: :string,
    gym_name: :string,
    plan: :string,
    active_until: :date,
    home_location: :string,
    claim_url: :string,
    opt_out_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "#{data.gym_name} is now on SimpleFit",
        preheader: "Claim your #{data.plan} membership — book and check in from your phone.",
        tag: "YOUR GYM",
        footer: :invitation
      }

      blocks = [
        {:heading, "Hi #{data.member_name}, your gym moved to SimpleFit."},
        {:paragraph,
         [
           "#{data.gym_name} now runs bookings, check-in and payments in the SimpleFit app. Your membership is waiting for you."
         ]},
        {:panel,
         [
           {:rows,
            [
              {"Membership", data.plan},
              {"Active until", Format.long_date(data.active_until)},
              {"Home location", data.home_location}
            ]}
         ]},
        {:bullets,
         [
           "Book classes and join waitlists",
           "Check in with a QR — no card needed",
           "Pay with BLIK or card, invoices included"
         ], :check},
        {:button, "Claim my membership", data.claim_url, :dark},
        {:panel,
         [
           {:paragraph,
            [
              {:strong, "Your privacy:"},
              " the gym shared your name, email and plan so you can claim your membership. Your training data stays private. ",
              {:link, "Don’t want this? Opt out", data.opt_out_url},
              " and we delete the invite."
            ], :note}
         ], :quiet}
      ]

      Layout.render(:member_invite, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:member_name, 80)
    |> Input.validate_line(:gym_name, 80)
    |> Input.validate_line(:plan, 60)
    |> Input.validate_line(:home_location, 60)
    |> Input.validate_url(:claim_url)
    |> Input.validate_url(:opt_out_url)
  end
end
