defmodule SimpleFit.Email.Templates.SponsorApplication do
  @moduledoc """
  Sponsor application emails (SF-114, ADR 0032). **No design exists for these**
  (SF-107: the canvas has no sponsor email; task S7). They are not in the designed
  inventory (`SimpleFit.Email.Templates.Inventory`), carry plain, factual copy
  pending design and copy approval, and are sent only where
  `config :simple_fit, SimpleFit.Sponsors, application_emails: true` (dev, test;
  off in production until approved).

  None of them says or implies approval, a partnership, a workspace, membership, an
  agreement or a payment: they describe what actually happened.

    * `received/1` - `:company_name`, `:resubmitted` (boolean)
    * `changes_requested/1` - `:company_name`, `:message` (the operator's text, 1..2000)
    * `contact_code/1` - `:code` (6 digits), `:expires_in_minutes`
  """

  import Ecto.Changeset

  alias SimpleFit.Email.Templates.{Input, Layout, Rendered}

  @spec received(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def received(attrs) do
    types = %{company_name: :string, resubmitted: :boolean}

    with {:ok, data} <- Input.validate(attrs, types, &Input.validate_line(&1, :company_name, 200)) do
      {subject, heading} =
        if data.resubmitted,
          do: {"We received your updated sponsor application", "Your updated application is in"},
          else: {"We received your sponsor application", "Your application is in"}

      Layout.render(
        :sponsor_application_received,
        %{
          subject: subject,
          preheader: "A person at SimpleFit will review it.",
          tag: "SPONSOR APPLICATION",
          footer: :activity
        },
        [
          {:heading, heading},
          {:paragraph, ["We received the application for ", {:strong, data.company_name}, "."]},
          {:paragraph,
           [
             "A person at SimpleFit reviews every application. We’ll email you when something changes."
           ]},
          {:paragraph,
           [
             "This doesn’t create a Sponsor workspace, a partnership, a payment or an agreement."
           ], :note}
        ]
      )
    end
  end

  @spec changes_requested(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def changes_requested(attrs) do
    types = %{company_name: :string, message: :string}

    checks = fn cs ->
      cs
      |> Input.validate_line(:company_name, 200)
      |> validate_length(:message, min: 1, max: 2000)
    end

    with {:ok, data} <- Input.validate(attrs, types, checks) do
      Layout.render(
        :sponsor_changes_requested,
        %{
          subject: "Changes requested on your sponsor application",
          preheader: "Update your answers and send them back.",
          tag: "SPONSOR APPLICATION",
          footer: :activity
        },
        [
          {:heading, "Changes requested"},
          {:paragraph,
           [
             "SimpleFit asked for changes to the application for ",
             {:strong, data.company_name},
             "."
           ]},
          {:panel, [{:label, "MESSAGE FROM SIMPLEFIT"}, {:paragraph, [data.message]}]},
          {:paragraph,
           ["Sign in to SimpleFit to update your answers and send the application back."]}
        ]
      )
    end
  end

  @spec contact_code(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def contact_code(attrs) do
    types = %{code: :string, expires_in_minutes: :integer}

    checks = fn cs ->
      cs
      |> validate_format(:code, ~r/\A\d{6}\z/)
      |> validate_number(:expires_in_minutes, greater_than: 0, less_than_or_equal_to: 1440)
    end

    with {:ok, data} <- Input.validate(attrs, types, checks) do
      Layout.render(
        :sponsor_contact_code,
        %{
          subject: "Your SimpleFit sponsor contact code: #{data.code}",
          preheader: "It confirms this address for a sponsor application.",
          tag: "SPONSOR APPLICATION",
          footer: :security
        },
        [
          {:heading, "Confirm this address"},
          {:paragraph,
           [
             "Someone named this address as the contact of a sponsor application on SimpleFit. Enter this code there to confirm it."
           ]},
          {:panel,
           [
             {:code, data.code, 44, :center},
             {:caption, "Expires in #{data.expires_in_minutes} minutes", :center}
           ]},
          {:paragraph,
           [
             "Confirming gives no access to SimpleFit or to any sponsor workspace. Didn’t expect this? Ignore this email."
           ], :note}
        ]
      )
    end
  end
end
