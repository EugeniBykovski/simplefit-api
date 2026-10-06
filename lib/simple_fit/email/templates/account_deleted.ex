defmodule SimpleFit.Email.Templates.AccountDeleted do
  @moduledoc """
  E15 · Account deleted (`project/EmailDeleted.dc.html`, ADR 0011).

  The last email to a deleted account, sent by the account-deletion
  lifecycle (expected SF-28) on the day of deletion.

  Required variables:

    * `:name` - the person's first name, one line, 1..80 characters
    * `:requested_on` - `Date` the deletion was requested
    * `:site_url` - absolute https URL of the public SimpleFit site

  Optional variables:

    * `:retained_gym_payments` - boolean, default `false`: shows the
      "Kept · anonymised" row; omitted otherwise

  The row values are the design's fixed policy copy.
  """

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @types %{name: :string, requested_on: :date, site_url: :string, retained_gym_payments: :boolean}

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1, [:retained_gym_payments]) do
      frame = %{
        subject: "Your SimpleFit account has been deleted",
        preheader: "This is the last email we’ll send you.",
        tag: "ACCOUNT",
        footer: :security
      }

      blocks = [
        {:heading, "Your account has been deleted."},
        {:paragraph,
         [
           "Hi #{String.trim(data.name)}. As you asked on #{Calendar.strftime(data.requested_on, "%b %-d")}, we permanently deleted your SimpleFit account and personal data today."
         ]},
        {:panel,
         [
           {:rows,
            [
              {"Deleted", "Profile, trainings, Board, messages"},
              if(data[:retained_gym_payments],
                do: {"Kept · anonymised", "Gym payments, 5 years (law)"}
              ),
              {"Email address", "Removed after this message"}
            ]}
         ]},
        {:paragraph,
         [
           "Thank you for training with us. If you come back, you’ll start fresh — nothing can be recovered."
         ]},
        {:button, "Visit SimpleFit", data.site_url, :outline}
      ]

      Layout.render(:account_deleted, frame, blocks)
    end
  end

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:name, 80)
    |> Input.validate_url(:site_url)
  end
end
