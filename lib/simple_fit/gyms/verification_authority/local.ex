# Compiled only outside production (SF-136): a production build has no such module.
if Mix.env() != :prod do
  defmodule SimpleFit.Gyms.VerificationAuthority.Local do
    @moduledoc """
    A fixture authority for tests and local development (SF-136). It proves nothing
    about a real person, and what it attributes is recorded as `local_fixture`.

    Operators come from configuration, read on every call so a test can revoke one
    at once:

        config :simple_fit, SimpleFit.Gyms.VerificationAuthority.Local,
          ambient_secret: "...",
          operators: [
            %{secret: "...", actor_id: "<uuid>", user_id: "<uuid>",
              permissions: [:approve], revoked: false, expires_at: nil}
          ]
    """

    @behaviour SimpleFit.Gyms.VerificationAuthority

    alias SimpleFit.Gyms.OperatorPrincipal

    defmodule Credential do
      @moduledoc "A fixture credential: a secret, never a name or an address."
      @enforce_keys [:secret]
      defstruct [:secret]
      @type t :: %__MODULE__{secret: String.t()}
    end

    @impl true
    def available?, do: true

    @impl true
    def ambient_credential do
      case config()[:ambient_secret] do
        secret when is_binary(secret) -> %Credential{secret: secret}
        _none -> nil
      end
    end

    @impl true
    def authenticate(%Credential{secret: secret}, permission) when is_binary(secret) do
      case Enum.find(config()[:operators] || [], &same?(&1.secret, secret)) do
        nil -> {:error, :unauthenticated}
        operator -> authorize(operator, permission)
      end
    end

    def authenticate(_credential, _permission), do: {:error, :unauthenticated}

    defp authorize(operator, permission) do
      cond do
        expired?(operator) ->
          {:error, :unauthenticated}

        Map.get(operator, :revoked, false) or permission not in operator.permissions ->
          {:error, {:forbidden, :operator}}

        true ->
          {:ok,
           %OperatorPrincipal{
             actor_id: operator.actor_id,
             user_id: operator.user_id,
             authority: :local_fixture
           }}
      end
    end

    defp expired?(operator) do
      case Map.get(operator, :expires_at) do
        nil -> false
        at -> DateTime.compare(at, DateTime.utc_now()) != :gt
      end
    end

    defp same?(left, right), do: Plug.Crypto.secure_compare(left, right)

    defp config, do: Application.get_env(:simple_fit, __MODULE__, [])
  end
end
