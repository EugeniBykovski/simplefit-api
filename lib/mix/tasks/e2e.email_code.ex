defmodule Mix.Tasks.E2e.EmailCode do
  @shortdoc "Prints the latest email sign-in/registration code queued to an address (dev/test only)"

  @moduledoc """
  Prints the 6-digit code of the latest E01/E17 email queued to an address,
  for local end-to-end runs against a real API on a disposable database
  (SF-30): the browser test enters the code a person would read in their
  inbox.

      $ MIX_ENV=dev DATABASE_URL=... mix e2e.email_code someone@example.com

  Queued email payloads stay encrypted (ADR 0011); this task opens them with
  the environment's own key, exactly as the delivery worker does. It runs
  only where `config :simple_fit, :e2e_tools, enabled: true` is set (dev and
  test; never in prod), and it is a Mix task, so it never ships in a
  release. It reads only; it changes nothing.
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Email.JobPayload
  alias SimpleFit.Repo

  @impl Mix.Task
  def run(args) do
    address =
      case args do
        [address] -> String.downcase(String.trim(address))
        _ -> Mix.raise("usage: mix e2e.email_code <address>")
      end

    Mix.Task.run("app.config")

    unless Application.get_env(:simple_fit, :e2e_tools, [])[:enabled] do
      Mix.raise("e2e.email_code runs only where :e2e_tools is enabled (dev and test)")
    end

    {:ok, _} = Application.ensure_all_started([:plug_crypto, :postgrex, :ecto_sql])
    start_repo()

    case latest_code(address) do
      {:ok, code} -> Mix.shell().info(code)
      :error -> Mix.raise("no code queued to that address")
    end
  end

  # Already running when called from the test suite.
  defp start_repo do
    case Repo.start_link(pool_size: 1, log: false) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp latest_code(address) do
    from(j in Oban.Job,
      where: j.worker == "SimpleFit.Email.DeliveryWorker",
      order_by: [desc: j.id],
      limit: 50,
      select: j.args
    )
    |> Repo.all()
    |> Enum.find_value(:error, fn args ->
      with {:ok, %{to: [^address], subject: subject}} <- JobPayload.open(args["payload"]),
           [_, code] <- Regex.run(~r/code: (\d{6})\z/, subject) do
        {:ok, code}
      else
        _ -> nil
      end
    end)
  end
end
