defmodule Mix.Tasks.Operators.DevCeremony do
  @shortdoc "Development only: signs a local operator ceremony statement"
  @moduledoc """
  **Development only** (SF-110). Signs a ceremony statement with a local key, for a
  local database:

      mix operators.dev_ceremony --user-id UUID --permissions operators.read,operators.manage,audit.read --out PATH
      mix operators.dev_ceremony --purpose recovery --user-id UUID --operator-id UUID --out PATH

  The key pair lives in `.operator-dev/` (outside Git) and is created on first use.
  Development trusts its public key on the next boot; ceremonies it signs are
  recorded as `local_development_ceremony`, never as a trusted ceremony. It refuses
  any environment other than `dev`, and the production build trusts no local key,
  so a statement it signs can't bootstrap production.
  """

  use Mix.Task

  @dir ".operator-dev"
  @build Mix.env()

  @impl Mix.Task
  def run(args) do
    if @build != :dev, do: Mix.raise("operators.dev_ceremony runs only with MIX_ENV=dev")

    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          user_id: :string,
          operator_id: :string,
          permissions: :string,
          purpose: :string,
          out: :string
        ]
      )

    out = opts[:out] || Mix.raise("--out is required")
    purpose = opts[:purpose] || "bootstrap"
    {public, private} = key_pair!()
    now = DateTime.utc_now()

    payload =
      Jason.encode!(%{
        version: 1,
        purpose: purpose,
        environment: "development",
        user_id: opts[:user_id] || Mix.raise("--user-id is required"),
        operator_id: opts[:operator_id],
        permissions:
          if(purpose == "bootstrap",
            do: String.split(opts[:permissions] || "", ",", trim: true),
            else: []
          ),
        ceremony_id: Ecto.UUID.generate(),
        issued_at: DateTime.to_iso8601(now),
        not_after: DateTime.to_iso8601(DateTime.add(now, 3600))
      })

    signature = :crypto.sign(:eddsa, :none, payload, [private, :ed25519])

    File.write!(
      out,
      Jason.encode!(%{
        key_id: "local-development",
        payload: Base.url_encode64(payload, padding: false),
        signature: Base.url_encode64(signature, padding: false)
      })
    )

    Mix.shell().info(
      "signed #{purpose} statement written to #{out} (public key #{Base.encode64(public)})"
    )
  end

  defp key_pair! do
    private_path = Path.join(@dir, "private.key")
    public_path = Path.join(@dir, "public.key")

    if File.exists?(private_path) do
      {Base.decode64!(String.trim(File.read!(public_path))),
       Base.decode64!(String.trim(File.read!(private_path)))}
    else
      File.mkdir_p!(@dir)
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      File.write!(private_path, Base.encode64(private))
      File.chmod!(private_path, 0o600)
      File.write!(public_path, Base.encode64(public))

      Mix.shell().info(
        "created a local development key pair in #{@dir}/ (restart the server to trust it)"
      )

      {public, private}
    end
  end
end
