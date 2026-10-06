defmodule SimpleFitWeb.MeJSON do
  @moduledoc "JSON rendering for `SimpleFitWeb.MeController` (`CurrentUserResponse`)."

  alias SimpleFit.Accounts.User

  @spec show(%{user: User.t()}) :: %{user: %{id: String.t(), created_at: String.t()}}
  def show(%{user: %User{} = user}) do
    %{user: %{id: user.id, created_at: DateTime.to_iso8601(user.inserted_at)}}
  end
end
