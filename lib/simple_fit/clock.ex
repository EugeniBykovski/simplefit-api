defmodule SimpleFit.Clock do
  @moduledoc """
  The current time for domain rules that depend on it (ADR 0023 scheduling
  windows).

  Every build except `:test` compiles `utc_now/0` to `DateTime.utc_now/0`:
  production behaviour is exactly the system clock. The `:test` build alone
  adds `freeze/1` and `unfreeze/0`, which pin the time for the calling test
  process (and tasks it starts), so date-dependent rules are tested at a
  controlled instant instead of against today's date.
  """

  if Mix.env() == :test do
    @spec utc_now() :: DateTime.t()
    def utc_now, do: frozen() || DateTime.utc_now()

    @doc false
    # Test-only: pins `utc_now/0` for this process and its tasks.
    @spec freeze(DateTime.t()) :: :ok
    def freeze(%DateTime{} = at) do
      Process.put(__MODULE__, at)
      :ok
    end

    @doc false
    @spec unfreeze() :: :ok
    def unfreeze do
      Process.delete(__MODULE__)
      :ok
    end

    defp frozen do
      Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> frozen_in(dictionary)
          nil -> nil
        end
      end)
    end

    defp frozen_in(dictionary) do
      case List.keyfind(dictionary, __MODULE__, 0) do
        {_key, %DateTime{} = at} -> at
        nil -> nil
      end
    end
  else
    @spec utc_now() :: DateTime.t()
    def utc_now, do: DateTime.utc_now()
  end
end
