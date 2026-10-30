defmodule Mix.Tasks.E2e.MemberInvitationToken do
  @shortdoc "Prints the token of the latest E07 member invitation email to an address (dev/test only)"

  @moduledoc """
  Prints the `sgm_` token of the latest E07 member invitation email queued
  to an address, for local end-to-end runs against a real API on a
  disposable database (SF-95, as `e2e.staff_invitation_token` for SF-93; the "e2e.invitation_link" task of SF-82 05): the test then
  previews and accepts on the web link's behalf, as a person would after
  opening the email.

      $ MIX_ENV=dev DATABASE_URL=... mix e2e.member_invitation_token someone@example.com

  Queued email payloads stay encrypted (ADR 0011); this task opens them with
  the environment's own key, exactly as the delivery worker does. It runs
  only where `config :simple_fit, :e2e_tools, enabled: true` is set (dev and
  test; never in prod), and it is a Mix task, so it never ships in a
  release. It reads only; it changes nothing. The caller must keep the token
  out of logs and files.
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
        _ -> Mix.raise("usage: mix e2e.member_invitation_token <address>")
      end

    Mix.Task.run("app.config")

    unless Application.get_env(:simple_fit, :e2e_tools, [])[:enabled] do
      Mix.raise(
        "e2e.member_invitation_token runs only where :e2e_tools is enabled (dev and test)"
      )
    end

    {:ok, _} = Application.ensure_all_started([:plug_crypto, :postgrex, :ecto_sql])
    start_repo()

    case latest_token(address) do
      {:ok, token} -> Mix.shell().info(token)
      :error -> Mix.raise("no member invitation queued to that address")
    end
  end

  # Already running when called from the test suite.
  defp start_repo do
    case Repo.start_link(pool_size: 1, log: false) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp latest_token(address) do
    from(j in Oban.Job,
      where: j.worker == "SimpleFit.Email.DeliveryWorker",
      order_by: [desc: j.id],
      limit: 50,
      select: j.args
    )
    |> Repo.all(log: false)
    |> Enum.find_value(:error, fn args ->
      with {:ok, %{to: [^address], text: text}} <- JobPayload.open(args["payload"]),
           [_, token] <- Regex.run(~r"/invite/gym#token=(sgm_[A-Za-z0-9_-]{43})", text) do
        {:ok, token}
      else
        _ -> nil
      end
    end)
  end
end
