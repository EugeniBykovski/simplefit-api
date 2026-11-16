defmodule SimpleFitWeb.SignInMethodJSON do
  @moduledoc "JSON rendering for `SimpleFitWeb.SignInMethodController` (`SignInMethodList`)."

  def index(%{methods: methods}), do: %{sign_in_methods: Enum.map(methods, &method/1)}

  defp method(%{provider: provider, email: email, linked_at: linked_at}),
    do: %{
      provider: Atom.to_string(provider),
      email: email,
      linked_at: DateTime.to_iso8601(linked_at)
    }
end
