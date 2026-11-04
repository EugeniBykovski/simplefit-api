defmodule Mix.Tasks.Gyms.Verification do
  @shortdoc "Operator review of gym business verification (list, show, documents, decisions)"

  @moduledoc """
  Operator review of gym business verification (SF-103;
  `SimpleFit.Gyms.VerificationReview`). Nothing here is reachable over
  HTTP. Every command names the operator by email address, and that address
  must be on the configured operator list (`GYM_VERIFICATION_OPERATORS`;
  none configured means review is disabled, SF-104). Every write is recorded
  in the application's append-only history; the operator must not be the
  application's creator or submitter or an active staff member of the gym.

      $ mix gyms.verification list --operator EMAIL
      $ mix gyms.verification show APPLICATION_ID --operator EMAIL
      $ mix gyms.verification document-url APPLICATION_ID EVIDENCE_ID --operator EMAIL
      $ mix gyms.verification approve APPLICATION_ID --revision N --operator EMAIL
      $ mix gyms.verification request-changes APPLICATION_ID --revision N --reason CODE --operator EMAIL
      $ mix gyms.verification reject APPLICATION_ID --revision N --reason CODE --operator EMAIL
      $ mix gyms.verification revoke APPLICATION_ID --reason CODE --operator EMAIL

  * `list` - submitted applications waiting for a decision, oldest first.
  * `show` - an application's details, documents and history (for the
    reviewing operator's terminal only).
  * `document-url` - a 5-minute download link for one confirmed document,
    recorded in the history. The link is a credential: open it, never paste
    it anywhere.
  * `approve`, `request-changes`, `reject` - decide a submitted application
    at the revision reviewed (a newer revision is refused).
  * `revoke` - withdraw an approval.

  Reason codes: `request-changes`
  #{Enum.map_join(SimpleFit.Gyms.VerificationPolicy.reasons(:changes_requested), ", ", &"`#{&1}`")};
  `reject` #{Enum.map_join(SimpleFit.Gyms.VerificationPolicy.reasons(:rejected), ", ", &"`#{&1}`")};
  `revoke` #{Enum.map_join(SimpleFit.Gyms.VerificationPolicy.reasons(:revoked), ", ", &"`#{&1}`")}.
  """

  use Mix.Task

  alias SimpleFit.Gyms.VerificationReview

  @switches [operator: :string, revision: :integer, reason: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)

    command(rest, opts)
  end

  defp command(["list"], opts) do
    case VerificationReview.list_submitted(opts[:operator]) do
      {:error, reason} ->
        fail(reason)

      {:ok, []} ->
        Mix.shell().info("no submitted applications")

      {:ok, rows} ->
        Enum.each(rows, fn %{application: a, gym_name: gym_name} ->
          Mix.shell().info(
            "#{a.id}  gym #{a.gym_id} (#{gym_name})  #{a.registration_country}  " <>
              "revision #{a.revision}  submitted #{DateTime.to_iso8601(a.submitted_at)}"
          )
        end)
    end
  end

  defp command(["show", id], opts) do
    case VerificationReview.show(id, opts[:operator]) do
      {:ok, detail} -> print(detail)
      {:error, reason} -> fail(reason)
    end
  end

  defp command(["document-url", id, evidence_id], opts) do
    case VerificationReview.evidence_download(id, evidence_id, opts[:operator]) do
      {:ok, download} ->
        Mix.shell().info("valid until #{DateTime.to_iso8601(download.expires_at)}:")
        Mix.shell().info(download.url)

      {:error, reason} ->
        fail(reason)
    end
  end

  defp command(["approve", id], opts), do: decide(id, :approved, opts)
  defp command(["request-changes", id], opts), do: decide(id, :changes_requested, opts)
  defp command(["reject", id], opts), do: decide(id, :rejected, opts)

  defp command(["revoke", id], opts) do
    id
    |> VerificationReview.revoke(Keyword.take(opts, [:operator, :reason]))
    |> report()
  end

  defp command(_args, _opts), do: Mix.raise("unknown command; see `mix help gyms.verification`")

  defp decide(id, decision, opts) do
    id
    |> VerificationReview.decide(decision, Keyword.take(opts, [:operator, :revision, :reason]))
    |> report()
  end

  defp report({:ok, application}),
    do:
      Mix.shell().info(
        "#{application.id}: #{application.status} (revision #{application.revision})"
      )

  defp report({:error, reason}), do: fail(reason)

  defp print(%{application: a, gym: gym, evidence: evidence, events: events}) do
    shell = Mix.shell()
    info = &shell.info/1

    info.(
      "application #{a.id} · #{a.status} · revision #{a.revision} · policy #{a.policy_version}"
    )

    info.("gym         #{gym.id} (#{gym.name})")
    info.("legal name  #{a.legal_name}")
    info.("country     #{a.registration_country}   registration number #{a.registration_number}")
    info.("address     #{a.address_line}, #{a.postal_code} #{a.city}")
    info.("website     #{a.website}")
    info.("documents:")

    Enum.each(evidence, fn e ->
      info.(
        "  #{e.id}  #{e.kind}  #{e.status}  #{e.content_type}  #{e.byte_size} B  " <>
          "#{e.file_name}#{if e.submitted_revision, do: "  (submitted r#{e.submitted_revision})"}"
      )
    end)

    info.("history:")

    Enum.each(events, fn e ->
      who = e.operator || "owner"
      reason = if e.reason_code, do: " (#{e.reason_code})", else: ""

      info.(
        "  #{DateTime.to_iso8601(e.occurred_at)}  #{e.event}#{reason}  r#{e.application_revision}  by #{who}"
      )
    end)
  end

  @spec fail(term()) :: no_return()
  defp fail(reason), do: Mix.raise("refused: #{inspect(reason)}")
end
