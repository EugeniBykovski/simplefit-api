defmodule SimpleFit.Email.Templates.FirstWeekRecap do
  @moduledoc """
  E12 · First week recap (`project/EmailWeek1.dc.html`, ADR 0011).

  A product (non-transactional) member email after the first week. The
  trigger is deferred: no training, Board or challenge domain exists yet,
  and no preference or unsubscribe system. The renderer only accepts
  presentation data.

  Required variables:

    * `:first_name` - 1..80
    * `:trainings`, `:rounds`, `:partners` - week totals, 0..100000
    * `:board_items` - 1..6 Board entries, each 1..60
    * `:board_url` - absolute https URL of the Board
    * `:preferences_url`, `:unsubscribe_url` - absolute https URLs for the
      member footer, supplied by the sender

  Optional variables (each group all or none):

    * challenge: `:challenge_name` (1..60), `:challenge_rank` and
      `:challenge_participants` (1..100000, rank not above participants) -
      the "Gym challenge" sentence
    * rival (only with a challenge): `:rival_name` (1..80) and
      `:rival_rounds_ahead` (1..100000) - "Mike is 8 rounds ahead" in the
      sentence and the preheader

  Weight and RPE are never accepted: the design promises they are never in
  emails.
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    first_name: :string,
    trainings: :integer,
    rounds: :integer,
    partners: :integer,
    board_items: {:array, :string},
    challenge_name: :string,
    challenge_rank: :integer,
    challenge_participants: :integer,
    rival_name: :string,
    rival_rounds_ahead: :integer,
    board_url: :string,
    preferences_url: :string,
    unsubscribe_url: :string
  }

  @max 100_000
  @challenge [:challenge_name, :challenge_rank, :challenge_participants]
  @rival [:rival_name, :rival_rounds_ahead]

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1, @challenge ++ @rival) do
      rival =
        if Map.has_key?(data, :rival_name),
          do:
            "#{data.rival_name} is #{Format.count(data.rival_rounds_ahead, "round", "rounds")} ahead"

      frame = %{
        subject:
          "Your first week: #{Format.count(data.trainings, "training", "trainings")}, #{Format.count(data.rounds, "round", "rounds")}",
        preheader: "Your Board has its first nodes#{if rival, do: " — and #{rival}"}.",
        tag: "WEEK 1",
        footer: {:member, data.preferences_url, data.unsubscribe_url}
      }

      blocks = [
        {:eyebrow, "YOUR FIRST WEEK"},
        {:heading, "Strong start, #{data.first_name}."},
        {:stats,
         [
           {Integer.to_string(data.trainings), "TRAININGS"},
           {Integer.to_string(data.rounds), "ROUNDS"},
           {Integer.to_string(data.partners), "PARTNERS"}
         ]},
        {:panel,
         [
           {:label, "YOUR BOARD"},
           {:caption, Enum.join(data.board_items, " · "), :left}
         ], :quiet},
        if(Map.has_key?(data, :challenge_name),
          do:
            {:paragraph,
             [
               {:strong, "Gym challenge:"},
               " you’re ##{data.challenge_rank} of #{data.challenge_participants} in “#{data.challenge_name}”." <>
                 if(rival, do: " #{rival}.", else: "")
             ]}
        ),
        {:button, "See your Board", data.board_url, :dark},
        {:paragraph, ["We send a recap once a week at most. Weight and RPE are never in emails."],
         :note}
      ]

      Layout.render(:first_week_recap, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:first_name, 80)
    |> validate_number(:trainings, greater_than_or_equal_to: 0, less_than_or_equal_to: @max)
    |> validate_number(:rounds, greater_than_or_equal_to: 0, less_than_or_equal_to: @max)
    |> validate_number(:partners, greater_than_or_equal_to: 0, less_than_or_equal_to: @max)
    |> Input.validate_lines(:board_items, 6, 60)
    |> Input.validate_together(@challenge)
    |> Input.validate_together(@rival)
    |> Input.validate_only_if(:rival_name, Input.present?(changeset, :challenge_name))
    |> Input.validate_only_if(:rival_rounds_ahead, Input.present?(changeset, :challenge_name))
    |> Input.validate_line(:challenge_name, 60)
    |> validate_number(:challenge_rank, greater_than_or_equal_to: 1, less_than_or_equal_to: @max)
    |> validate_number(:challenge_participants,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max
    )
    |> validate_rank()
    |> Input.validate_line(:rival_name, 80)
    |> validate_number(:rival_rounds_ahead,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max
    )
    |> Input.validate_url(:board_url)
    |> Input.validate_url(:preferences_url)
    |> Input.validate_url(:unsubscribe_url)
  end

  defp validate_rank(changeset) do
    validate_change(changeset, :challenge_rank, fn :challenge_rank, rank ->
      participants = get_field(changeset, :challenge_participants)

      if is_integer(participants) and rank > participants,
        do: [challenge_rank: {"must not exceed participants", validation: :number}],
        else: []
    end)
  end
end
