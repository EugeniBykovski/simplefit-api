defmodule Mix.Tasks.Sponsors.Fixture do
  @shortdoc "Development only: provisions local sponsor organizations and memberships"
  @moduledoc """
  **Development only** (SF-112). Drives `SimpleFit.Sponsors.Provisioning` with the
  local fixture authority, for a local database, standing in for the Sponsor
  Application approval that doesn't exist yet:

      mix sponsors.fixture provision --owner-user-id UUID --legal-name "Acme Sp. z o.o." \\
        --display-name Acme --country PL --contact-name "Ada Nowak" --contact-email ada@acme.example
      mix sponsors.fixture add-member --organization-id UUID --user-id UUID --role member
      mix sponsors.fixture suspend-membership --membership-id UUID --reason e2e_check
      mix sponsors.fixture revoke-membership --membership-id UUID --reason e2e_check

  Everything it does is recorded with authority `local_fixture`, which is never
  trust. It refuses any environment other than `dev`, and a production build has no
  fixture authority at all.
  """

  use Mix.Task

  alias SimpleFit.Sponsors.Provisioning

  @build Mix.env()

  @impl Mix.Task
  def run([command | args]) do
    if @build != :dev, do: Mix.raise("sponsors.fixture runs only with MIX_ENV=dev")
    Mix.Task.run("app.start")

    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          owner_user_id: :string,
          legal_name: :string,
          display_name: :string,
          country: :string,
          contact_name: :string,
          contact_email: :string,
          organization_id: :string,
          user_id: :string,
          role: :string,
          membership_id: :string,
          reason: :string
        ]
      )

    {:ok, authority} = Provisioning.local_fixture_authority()
    report(command, execute(command, authority, opts))
  end

  def run(_args), do: Mix.raise("usage: see `mix help sponsors.fixture`")

  defp execute("provision", authority, opts) do
    Provisioning.provision_organization(authority, %{
      provisioning_key: Ecto.UUID.generate(),
      legal_name: opts[:legal_name],
      display_name: opts[:display_name],
      country_code: opts[:country],
      owner_user_id: opts[:owner_user_id],
      contacts: [
        %{kind: "primary", full_name: opts[:contact_name], email: opts[:contact_email]}
      ]
    })
  end

  defp execute("add-member", authority, opts) do
    role =
      case opts[:role] do
        "manager" -> :manager
        "member" -> :member
        _ -> Mix.raise("--role must be manager or member")
      end

    Provisioning.add_member(authority, opts[:organization_id], opts[:user_id], role)
  end

  defp execute("suspend-membership", authority, opts),
    do: Provisioning.suspend_membership(authority, opts[:membership_id], opts[:reason])

  defp execute("revoke-membership", authority, opts),
    do: Provisioning.revoke_membership(authority, opts[:membership_id], opts[:reason])

  defp execute(command, _authority, _opts), do: Mix.raise("unknown command #{command}")

  # Ids and states only: never names, emails or contacts.
  defp report("provision", {:ok, %{organization: org, owner: owner}}),
    do:
      Mix.shell().info(
        "provisioned organization #{org.id} (local_fixture), owner membership #{owner.id}"
      )

  defp report(_command, {:ok, %{id: id, status: status}}),
    do: Mix.shell().info("membership #{id} is #{status}")

  defp report(command, {:error, reason}),
    do: Mix.raise("#{command} refused: #{inspect(reason, limit: 5, printable_limit: 120)}")
end
