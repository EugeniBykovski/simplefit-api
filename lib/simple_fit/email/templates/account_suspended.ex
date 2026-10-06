defmodule SimpleFit.Email.Templates.AccountSuspended do
  @moduledoc """
  E13 · Account suspended (`project/EmailSuspended.dc.html`, ADR 0011).

  Sent when moderation suspends an account. The trigger is deferred: no
  moderation, report or appeal domain exists yet. The renderer only accepts
  presentation data; it suspends nothing.

  Required variables:

    * `:name` - 1..80
    * `:case_id` - moderation case reference ("RPT-20938"): uppercase
      letters and digits in dash-separated groups, 1..32
    * `:suspended_until` - `Date` the suspension ends
    * `:content_kind` - what was reported ("comments"), 1..40
    * `:posted_on` - `Date` the content was posted
    * `:rule` - the broken rule ("§3.2 · No insults or threats"), 1..80
    * `:suspension` - display ("14 days · ends Oct 18, 12:41"), 1..60
    * `:appeal_url` - absolute https URL of the appeal

  Optional variables (each omits its row):

    * `:content_removed` - display ("4 comments"), 1..60
    * `:previous_notices` - display ("1 warning · Aug 14"), 1..60

  What still works, what is paused, the appeal window and the 90-day
  warning are the design's fixed policy copy.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    name: :string,
    case_id: :string,
    suspended_until: :date,
    content_kind: :string,
    posted_on: :date,
    rule: :string,
    content_removed: :string,
    suspension: :string,
    previous_notices: :string,
    appeal_url: :string
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <-
           Input.validate(attrs, @types, &checks/1, [:content_removed, :previous_notices]) do
      until = Format.short_date(data.suspended_until)

      frame = %{
        subject: "Your SimpleFit account is suspended until #{until}",
        preheader: "Why, what still works, and how to appeal.",
        tag: "ACCOUNT NOTICE",
        footer: :security
      }

      blocks = [
        {:eyebrow, "CASE #{data.case_id}", :danger},
        {:heading, "Your account is suspended until #{until}."},
        {:paragraph,
         [
           "Hi #{data.name}. A moderator reviewed reports about #{data.content_kind} you posted on #{Format.short_date(data.posted_on)} and found they broke our Community guidelines."
         ]},
        {:panel,
         [
           {:rows,
            [
              {"Rule", data.rule},
              data[:content_removed] && {"Content removed", data.content_removed},
              {"Suspension", data.suspension},
              data[:previous_notices] && {"Previous notices", data.previous_notices}
            ]}
         ]},
        {:panel,
         [
           {:label, "STILL WORKS"},
           {:bullets,
            [
              "Round timer, training log and your own data",
              "Gym bookings, check-in and payments"
            ], :check},
           {:label, "PAUSED UNTIL #{String.upcase(until)}"},
           {:bullets, ["Comments, posts, invites and messages"], :dash}
         ]},
        {:paragraph,
         ["Think we got it wrong? A different moderator reviews appeals within 72 hours."]},
        {:button, "Appeal this decision", data.appeal_url, :dark},
        {:paragraph, ["Another violation within 90 days may lead to a permanent ban."], :note}
      ]

      Layout.render(:account_suspended, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:name, 80)
    |> validate_format(:case_id, ~r/\A[A-Z0-9]+(-[A-Z0-9]+)*\z/)
    |> validate_length(:case_id, max: 32)
    |> Input.validate_line(:content_kind, 40)
    |> Input.validate_line(:rule, 80)
    |> Input.validate_line(:content_removed, 60)
    |> Input.validate_line(:suspension, 60)
    |> Input.validate_line(:previous_notices, 60)
    |> Input.validate_url(:appeal_url)
  end
end
