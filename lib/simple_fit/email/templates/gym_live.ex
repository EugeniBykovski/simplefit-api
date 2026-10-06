defmodule SimpleFit.Email.Templates.GymLive do
  @moduledoc """
  E05 · Your gym is live (`EmailGymLive.dc.html`, ADR 0011).

  Sent to the gym owner when the gym is published. The trigger is deferred:
  no gym, location, member-import, verification or payout domain exists
  yet. The renderer only accepts presentation data.

  Variables (all required):

    * `:gym_name` - 1..80
    * `:published_on` - `Date` the gym was published
    * `:city` - where the gym appears in Discover ("Warsaw"), 1..60
    * `:payout_day` - weekday of bank payouts, `"Monday"`..`"Sunday"`
    * `:public_page_url` - absolute https URL, shown without its scheme
    * `:locations` - 1..20 location names, each 1..40
    * `:member_invites` - display summary ("175 · tomorrow 10:00"), 1..60
    * `:verification_status` - display status ("Proof of address in review"), 1..80
    * `:dashboard_url` - absolute https URL of the gym dashboard

  The three next steps are the design's fixed copy.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @types %{
    gym_name: :string,
    published_on: :date,
    city: :string,
    payout_day: :string,
    public_page_url: :string,
    locations: {:array, :string},
    member_invites: :string,
    verification_status: :string,
    dashboard_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1) do
      frame = %{
        subject: "#{data.gym_name} is live",
        preheader: "Members can find you, book and pay from today.",
        tag: "YOU’RE LIVE",
        footer: :activity
      }

      blocks = [
        {:eyebrow, "PUBLISHED · #{String.upcase(Format.short_date(data.published_on))}"},
        {:heading, "#{data.gym_name} is live."},
        {:paragraph,
         [
           "You’re in Discover in #{data.city}, bookings are open and payments go to your bank every #{data.payout_day}."
         ]},
        {:panel,
         [
           {:rows,
            [
              {"Public page", Format.bare_url(data.public_page_url)},
              {"Locations", Enum.join(data.locations, " · ")},
              {"Member invites", data.member_invites},
              {"Verification", data.verification_status}
            ]}
         ]},
        {:steps,
         [
           {"Print your check-in QR stands",
            "One per front desk · codes rotate so they can’t be shared."},
           {"Run your first class from the app",
            "Rosters, check-in and incidents in the Gym app."},
           {"Set your first monthly challenge", "Rounds-based, opt-in leaderboards."}
         ]},
        {:button, "Open dashboard", data.dashboard_url, :dark}
      ]

      Layout.render(:gym_live, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:gym_name, 80)
    |> Input.validate_line(:city, 60)
    |> validate_inclusion(:payout_day, @weekdays)
    |> Input.validate_url(:public_page_url)
    |> Input.validate_lines(:locations, 20, 40)
    |> Input.validate_line(:member_invites, 60)
    |> Input.validate_line(:verification_status, 80)
    |> Input.validate_url(:dashboard_url)
  end
end
