defmodule SimpleFitWeb.AdminUserJSON do
  @moduledoc "Renders operator account administration (SF-122): allowlisted fields only."

  def search(%{users: users}), do: %{users: Enum.map(users, &summary/1)}

  def show(%{user: user}) do
    %{
      user:
        user
        |> summary()
        |> Map.merge(%{
          revision: user.revision,
          suspension: user.suspension,
          registration: user.registration,
          providers: user.providers,
          sessions: Enum.map(user.sessions, &Map.take(&1, [:started_at, :expires_at])),
          last_sign_in_at: user.last_sign_in_at
        })
    }
  end

  def email(%{email: email}), do: %{email_addresses: email.email_addresses}

  def state(%{user: user}), do: %{user: Map.take(user, [:id, :status, :revision])}

  defp summary(user) do
    %{
      id: user.id,
      name: user.name,
      joined_at: user.joined_at,
      status: user.status,
      masked_emails: user.masked_emails,
      contexts: user.contexts
    }
  end
end
