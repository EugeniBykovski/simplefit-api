defmodule SimpleFit.OperatorHelpers do
  @moduledoc """
  SF-110 test helpers: ceremony keys generated per run (no private key is
  committed), signed statements, and a software WebAuthn authenticator (ES256)
  that produces real registration and assertion responses for `wax_`.

  A software authenticator proves the protocol and the server's checks; it is not
  evidence about any physical security key.
  """

  alias SimpleFit.Accounts.{Session, User}
  alias SimpleFit.Operators
  alias SimpleFit.Operators.{Bootstrap, WebAuthn}

  @origin "http://localhost:3000"
  @rp_id "localhost"

  ## Ceremony keys and statements

  @doc "Creates a key pair, trusts its public key as `kid`, returns the private key."
  def trust_ceremony_key!(kid \\ "test-ceremony", kind \\ :signed_ceremony) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    config = Application.get_env(:simple_fit, Bootstrap, [])
    keys = Map.put(Keyword.get(config, :trusted_keys, %{}), kid, {Base.encode64(public), kind})
    Application.put_env(:simple_fit, Bootstrap, Keyword.put(config, :trusted_keys, keys))
    private
  end

  @doc "Removes every trusted ceremony key."
  def untrust_ceremony_keys! do
    config = Application.get_env(:simple_fit, Bootstrap, [])
    Application.put_env(:simple_fit, Bootstrap, Keyword.put(config, :trusted_keys, %{}))
  end

  @doc "A signed statement (JSON) with `overrides` on top of valid bootstrap claims."
  def statement(private, %User{} = user, overrides \\ %{}, kid \\ "test-ceremony") do
    now = DateTime.utc_now()

    claims =
      Map.merge(
        %{
          "version" => 1,
          "purpose" => "bootstrap",
          "environment" => "test",
          "user_id" => user.id,
          "permissions" => ["operators.read", "operators.manage", "audit.read"],
          "ceremony_id" => Ecto.UUID.generate(),
          "issued_at" => DateTime.to_iso8601(now),
          "not_after" => DateTime.to_iso8601(DateTime.add(now, 3600))
        },
        overrides
      )

    payload = Jason.encode!(claims)

    Jason.encode!(%{
      "key_id" => kid,
      "payload" => Base.url_encode64(payload, padding: false),
      "signature" =>
        Base.url_encode64(:crypto.sign(:eddsa, :none, payload, [private, :ed25519]),
          padding: false
        )
    })
  end

  @doc "Bootstraps `user` as the founder (asserting success)."
  def bootstrap!(
        %User{} = user,
        permissions \\ ["operators.read", "operators.manage", "audit.read"]
      ) do
    private = trust_ceremony_key!()
    {:ok, operator} = Bootstrap.run(statement(private, user, %{"permissions" => permissions}))
    operator
  end

  ## Software authenticator

  defmodule SoftKey do
    @moduledoc "An ES256 software authenticator (test only)."
    defstruct [
      :private,
      :x,
      :y,
      :credential_id,
      counter: 0,
      backup_eligible: false,
      user_verified: true
    ]
  end

  @doc "A new software key."
  def soft_key(opts \\ []) do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private} =
      :crypto.generate_key(:ecdh, :secp256r1)

    %SoftKey{
      private: private,
      x: x,
      y: y,
      credential_id: :crypto.strong_rand_bytes(32),
      backup_eligible: Keyword.get(opts, :backup_eligible, false),
      user_verified: Keyword.get(opts, :user_verified, true)
    }
  end

  @doc "A registration response to `options` (as `registration_options/3` returned them)."
  def registration_response(
        %SoftKey{} = key,
        %{challenge_id: id, options: opts},
        overrides \\ %{}
      ) do
    origin = Map.get(overrides, :origin, @origin)
    rp_id = Map.get(overrides, :rp_id, @rp_id)
    challenge = Map.get(overrides, :challenge, opts.challenge)

    cose = %{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => %CBOR.Tag{tag: :bytes, value: key.x},
      -3 => %CBOR.Tag{tag: :bytes, value: key.y}
    }

    attested =
      <<0::128, byte_size(key.credential_id)::16>> <> key.credential_id <> CBOR.encode(cose)

    auth_data =
      :crypto.hash(:sha256, rp_id) <> <<flags(key, true)>> <> <<key.counter::32>> <> attested

    attestation =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    client_data =
      Jason.encode!(%{
        type: "webauthn.create",
        challenge: challenge,
        origin: origin,
        crossOrigin: false
      })

    %{
      "challenge_id" => id,
      "attestation_object" => WebAuthn.b64(attestation),
      "client_data_json" => WebAuthn.b64(client_data),
      "label" => "Test key"
    }
  end

  @doc "An assertion to `options`; returns the response and the key with its counter advanced."
  def assertion_response(%SoftKey{} = key, %{challenge_id: id, options: opts}, overrides \\ %{}) do
    key = %{key | counter: Map.get(overrides, :counter, key.counter + 1)}
    origin = Map.get(overrides, :origin, @origin)
    rp_id = Map.get(overrides, :rp_id, @rp_id)
    challenge = Map.get(overrides, :challenge, opts.challenge)
    auth_data = :crypto.hash(:sha256, rp_id) <> <<flags(key, false)>> <> <<key.counter::32>>

    client_data =
      Jason.encode!(%{
        type: "webauthn.get",
        challenge: challenge,
        origin: origin,
        crossOrigin: false
      })

    signed = auth_data <> :crypto.hash(:sha256, client_data)
    signature = :crypto.sign(:ecdsa, :sha256, signed, [key.private, :secp256r1])

    {%{
       "challenge_id" => id,
       "credential_id" => WebAuthn.b64(key.credential_id),
       "authenticator_data" => WebAuthn.b64(auth_data),
       "client_data_json" => WebAuthn.b64(client_data),
       "signature" => WebAuthn.b64(signature)
     }, key}
  end

  # UP 0x01, UV 0x04, BE 0x08, AT 0x40
  defp flags(key, attested?) do
    0x01 + if(key.user_verified, do: 0x04, else: 0) + if(key.backup_eligible, do: 0x08, else: 0) +
      if(attested?, do: 0x40, else: 0)
  end

  ## Journeys

  @doc "Registers `count` new software keys; returns them."
  def enroll!(%User{} = user, %Session{} = session, count \\ 2) do
    for _ <- 1..count do
      key = soft_key()
      {:ok, options} = Operators.registration_options(user, session)
      {:ok, _} = Operators.register_credential(user, session, registration_response(key, options))
      key
    end
  end

  @doc "Completes a key check with `key`; returns the key with its counter advanced."
  def step_up!(%User{} = user, %Session{} = session, key) do
    {:ok, options} = Operators.step_up_options(user, session)
    {response, key} = assertion_response(key, options)
    {:ok, _step_up} = Operators.verify_step_up(user, session, response)
    key
  end

  @doc "A fresh operation payload."
  def op(reason \\ "test_reason"),
    do: %{"reason_code" => reason, "operation_id" => Ecto.UUID.generate()}
end
