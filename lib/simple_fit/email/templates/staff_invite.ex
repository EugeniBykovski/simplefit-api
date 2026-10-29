defmodule SimpleFit.Email.Templates.StaffInvite do
  @moduledoc """
  E06 · Staff invitation (`project/EmailStaffInvite.dc.html`, ADR 0011).

  Sent when a gym's owner or a manager invites someone to the gym team
  (SF-93, `SimpleFit.Gyms`). The renderer only accepts presentation data; it
  creates no invitation and no token.

  SF-93 sends it without `:invitee_name` and `:location`: a staff invitation
  is addressed to an email, not to a named person, and assigns no location
  (ADR 0026: the home location is the staff member's later choice, OS3). The
  artboard's greeting and location line appear only when they are given.

  Variables (required unless marked optional):

    * `:invitee_name` - optional, 1..80
    * `:inviter_name` - inviter as named in the subject ("Yauheni"), 1..80
    * `:inviter_display_name` - inviter as named in the body ("Yauheni B."), 1..80
    * `:inviter_role` - the inviter's role ("owner"), 1..40
    * `:gym_name` - 1..80
    * `:role` - the offered role ("Front desk"), 1..40
    * `:location` - optional, the location ("Praga"), 1..60
    * `:permissions` - 1..8 lines of what the role can do, each 1..80
    * `:accept_url` - absolute https URL; any credential in it belongs to
      the sending domain
    * `:expires_on` - `Date` the invitation expires
  """

  alias SimpleFit.Email.Templates.{Format, Input, Layout, Rendered}

  @types %{
    invitee_name: :string,
    inviter_name: :string,
    inviter_display_name: :string,
    inviter_role: :string,
    gym_name: :string,
    role: :string,
    location: :string,
    permissions: {:array, :string},
    accept_url: :string,
    expires_on: :date
  }

  @spec render(map() | keyword()) :: {:ok, Rendered.t()} | {:error, Input.error()}
  def render(attrs) do
    with {:ok, data} <- Input.validate(attrs, @types, &checks/1, [:invitee_name, :location]) do
      frame = %{
        subject: "#{data.inviter_name} invited you to #{data.gym_name}",
        preheader: "Join the team as #{data.role}#{location_suffix(data)}.",
        tag: "INVITATION",
        footer: :invitation
      }

      blocks = [
        {:identity, nil, "TEAM INVITATION", data.gym_name, nil},
        {:heading, greeting(data), 24},
        {:paragraph,
         [
           {:strong, data.inviter_display_name},
           " (#{data.inviter_role}) invited you as ",
           {:strong, data.role},
           at_location(data)
         ]},
        {:panel, [{:label, "YOU’LL BE ABLE TO"}, {:bullets, data.permissions, :olive}]},
        {:button, "Accept invitation", data.accept_url, :dark},
        {:paragraph,
         [
           "The invitation expires on ",
           {:strong, Format.short_date(data.expires_on)},
           ". Accepting links it to your own SimpleFit account — your personal data stays yours if you leave."
         ], :note}
      ]

      Layout.render(:staff_invite, frame, blocks)
    end
  end

  defp greeting(%{invitee_name: name}), do: "Hi #{name}, you’re invited to the team."
  defp greeting(_data), do: "You’re invited to the team."

  defp location_suffix(%{location: location}), do: " · #{location}"
  defp location_suffix(_data), do: ""

  defp at_location(%{location: location}), do: " at the #{location} location."
  defp at_location(_data), do: "."

  defp checks(changeset) do
    changeset
    |> Input.validate_line(:invitee_name, 80)
    |> Input.validate_line(:inviter_name, 80)
    |> Input.validate_line(:inviter_display_name, 80)
    |> Input.validate_line(:inviter_role, 40)
    |> Input.validate_line(:gym_name, 80)
    |> Input.validate_line(:role, 40)
    |> Input.validate_line(:location, 60)
    |> Input.validate_lines(:permissions, 8, 80)
    |> Input.validate_url(:accept_url)
  end
end
