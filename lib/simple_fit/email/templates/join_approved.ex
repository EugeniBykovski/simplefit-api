defmodule SimpleFit.Email.Templates.JoinApproved do
  @moduledoc """
  E09 · Join request approved (`EmailJoinApproved.dc.html`, ADR 0011).

  Sent when a gym's front desk confirms a membership. The trigger is
  deferred: no gym membership, billing or booking domain exists yet. The
  renderer only accepts presentation data.

  Variables (all required):

    * `:gym_name` - 1..80
    * `:staff_name` - who confirmed ("Natalia"), 1..80
    * `:plan` - plan display ("Monthly · unlimited classes"), 1..80
    * `:next_billing` - billing display ("Nov 1 · €79 · Visa •• 4242"), 1..80;
      never a full card number
    * `:booked` - booking display ("Tue 19:30 Pads · Ring 1"), 1..80
    * `:notice_days` - cancellation notice agreed with the gym, 0..365
    * `:checkin_url` - absolute https URL of the check-in QR
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{
    gym_name: :string,
    staff_name: :string,
    plan: :string,
    next_billing: :string,
    booked: :string,
    notice_days: :integer,
    checkin_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "You’re in at #{data.gym_name}",
        preheader: "Your membership is confirmed — check in with your phone.",
        tag: "MEMBERSHIP",
        footer: :activity
      }

      blocks = [
        {:eyebrow, "CONFIRMED BY FRONT DESK"},
        {:heading, "You’re in at #{data.gym_name}."},
        {:paragraph,
         [
           "#{data.staff_name} confirmed your membership at the front desk. From now on, check in with your phone."
         ]},
        {:panel,
         [
           {:rows,
            [{"Plan", data.plan}, {"Next billing", data.next_billing}, {"Booked", data.booked}]}
         ]},
        {:button, "Show my check-in QR", data.checkin_url, :dark},
        {:paragraph,
         [
           "Cancel or freeze in the app any time — #{data.notice_days} days notice, as agreed with the gym."
         ], :note}
      ]

      Layout.render(:join_approved, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:gym_name, 80)
    |> Input.validate_line(:staff_name, 80)
    |> Input.validate_line(:plan, 80)
    |> Input.validate_line(:next_billing, 80)
    |> Input.validate_line(:booked, 80)
    |> validate_number(:notice_days, greater_than_or_equal_to: 0, less_than_or_equal_to: 365)
    |> Input.validate_url(:checkin_url)
  end
end
