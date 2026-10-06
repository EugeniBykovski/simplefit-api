defmodule SimpleFit.Email.Templates.GymSetup do
  @moduledoc """
  E04 · Finish gym setup (`project/EmailWelcomeGym.dc.html`, ADR 0011).

  Reminds a gym owner to finish setting up their gym. The trigger is
  deferred: no gym or onboarding domain exists yet.

  The email does not authenticate anyone. "Continue setup" is a plain
  navigation link supplied by the future owner; the person signs in as
  usual if needed and returns to their setup (the design's copy says so).
  No token, sign-in link or resume state belongs to this template.

  Required variables:

    * `:gym_name` - 1..80
    * `:continue_url` - absolute https URL of the gym setup

  Optional variables (both or neither):

    * `:progress_completed` and `:progress_total` - setup progress shown as
      "GYM SETUP · 3 OF 14 DONE" and a segmented bar; `total` is 1..30
      (the bar has one segment per step) and `completed` is 0..total-1,
      since a finished setup has nothing left to continue. Without progress
      the eyebrow reads "GYM SETUP" and the bar is omitted.

  The "Have these ready" list is the design's fixed copy.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @progress [:progress_completed, :progress_total]
  @max_steps 30

  @types %{
    gym_name: :string,
    continue_url: :string,
    progress_completed: :integer,
    progress_total: :integer
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1, @progress) do
      progress =
        if Map.has_key?(data, :progress_total),
          do: {data.progress_completed, data.progress_total}

      frame = %{
        subject: "Finish setting up #{data.gym_name}",
        preheader: "Pick up where you left off — about 20 minutes on a computer.",
        tag: "GYM SETUP",
        footer: :activity
      }

      blocks = [
        {:eyebrow, eyebrow(progress)},
        {:heading, "Let’s get #{data.gym_name} live."},
        with({completed, total} <- progress, do: {:progress, completed, total}),
        {:paragraph,
         [
           "Pick up where you left off on any computer. If you’re not signed in, you’ll sign in as usual and go straight back to your setup."
         ]},
        {:button, "Continue setup", data.continue_url, :dark},
        {:panel,
         [
           {:label, "HAVE THESE READY"},
           {:bullets,
            [
              "Company details and NIP for payouts",
              "Logo and a wide photo of the gym",
              "Your price list and class timetable",
              "A CSV export of current members (optional)"
            ], :olive}
         ]}
      ]

      Layout.render(:gym_setup, frame, blocks)
    end
  end

  defp eyebrow(nil), do: "GYM SETUP"
  defp eyebrow({completed, total}), do: "GYM SETUP · #{completed} OF #{total} DONE"

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:gym_name, 80)
    |> Input.validate_url(:continue_url)
    |> Input.validate_together(@progress)
    |> validate_number(:progress_total,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_steps
    )
    |> validate_number(:progress_completed, greater_than_or_equal_to: 0)
    |> validate_change(:progress_completed, fn :progress_completed, completed ->
      total = get_field(changeset, :progress_total)

      if is_integer(total) and completed >= total,
        do: [progress_completed: {"must be below the total", validation: :number}],
        else: []
    end)
  end
end
