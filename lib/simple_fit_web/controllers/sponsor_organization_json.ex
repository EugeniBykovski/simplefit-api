defmodule SimpleFitWeb.SponsorOrganizationJSON do
  @moduledoc "Sponsor organization DTOs (SF-112). Fields picked explicitly: no provisioning internals."

  alias SimpleFit.Sponsors.{Contact, Organization, Policy}

  def index(%{organizations: list}),
    do: %{organizations: Enum.map(list, &organization_view/1)}

  def show(%{access: access}), do: organization_view(access)

  def members(%{page: page}),
    do: %{
      members: Enum.map(page.entries, &member/1),
      next_cursor: page.next_cursor
    }

  def contacts(%{contacts: contacts}), do: %{contacts: Enum.map(contacts, &contact/1)}

  defp organization_view(%{organization: o, membership: m} = access) do
    %{
      organization: organization(o),
      membership: %{
        membership_id: m.id,
        role: Atom.to_string(m.role),
        permissions:
          Enum.map(
            Map.get(access, :permissions) || Policy.for_role(m.role),
            &Atom.to_string/1
          ),
        joined_at: m.inserted_at
      }
    }
  end

  defp organization(%Organization{} = o) do
    %{
      sponsor_id: o.id,
      legal_name: o.legal_name,
      display_name: o.display_name,
      country_code: o.country_code,
      website: o.website,
      status: Atom.to_string(o.status),
      revision: o.revision,
      created_at: o.inserted_at
    }
  end

  defp member(entry) do
    %{
      membership_id: entry.membership_id,
      short_name: entry.short_name,
      role: Atom.to_string(entry.role),
      status: Atom.to_string(entry.status),
      joined_at: entry.joined_at,
      is_viewer: entry.is_viewer
    }
  end

  defp contact(%Contact{} = c) do
    %{
      contact_id: c.id,
      kind: Atom.to_string(c.kind),
      full_name: c.full_name,
      job_title: c.job_title,
      email: c.email,
      phone: c.phone
    }
  end
end
