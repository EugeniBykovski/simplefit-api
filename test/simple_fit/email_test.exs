defmodule SimpleFit.EmailTest do
  # Not async: one test removes the payload key from the app env.
  use SimpleFit.DataCase, async: false
  use Oban.Testing, repo: SimpleFit.Repo

  alias SimpleFit.Email
  alias SimpleFit.Email.{DeliveryWorker, JobPayload, Message}

  setup do
    {:ok, message} = Message.new(to: "fighter@example.com", subject: "Welcome", text: "Hello")
    %{message: message}
  end

  describe "deliver/2" do
    test "delivers through the configured adapter (never the network in test)", %{
      message: message
    } do
      assert {:ok, %{id: "test-" <> _}} = Email.deliver(message, idempotency_key: "k1")
      assert_received {:email_delivered, ^message, [idempotency_key: "k1"]}
    end

    test "emits telemetry with adapter and result only", %{message: message} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:simple_fit, :email, :deliver, :stop]])

      Email.deliver(message)

      assert_received {[:simple_fit, :email, :deliver, :stop], ^ref, %{duration: _},
                       %{adapter: SimpleFit.EmailTestAdapter, result: :ok} = metadata}

      refute Map.has_key?(metadata, :message)
    end
  end

  # Leakage checks look for full, long sensitive values only (32+ characters):
  # a fixed string of that length occurs in random ciphertext with probability
  # below 2^-190, so the checks cannot fail by chance. Short words ("to",
  # "Hello") occur in random base64 output by chance and are never asserted.
  @secret_to "fighter.payload-confidentiality@example.com"
  @secret_token "sfp-7f3c9a2e5b8d4c1f6a0e9b3d7c2f5a8e"
  @secret_subject "Your SimpleFit sign-in code for the payload confidentiality check"

  defp secret_message do
    {:ok, message} =
      Message.new(
        to: @secret_to,
        subject: @secret_subject,
        text: "Use the one-time token #{@secret_token} to continue."
      )

    message
  end

  defp secret_values, do: [@secret_to, @secret_token, @secret_subject]

  defp sealed(message) do
    {:ok, payload} = JobPayload.seal(message)
    %{"payload" => payload}
  end

  describe "deliver_later/1" do
    test "enqueues the message in the mailers queue without sending it", %{message: message} do
      assert {:ok, %Oban.Job{args: %{"payload" => payload} = args}} = Email.deliver_later(message)

      assert_enqueued(worker: DeliveryWorker, queue: :mailers, args: args)
      assert JobPayload.open(payload) == {:ok, message}
      refute_received {:email_delivered, _, _}
    end

    test "stores only ciphertext in the job arguments" do
      message = secret_message()
      {:ok, job} = Email.deliver_later(message)
      stored = Repo.get!(Oban.Job, job.id)

      assert Map.keys(stored.args) == ["payload"]
      assert JobPayload.open(stored.args["payload"]) == {:ok, message}

      for secret <- secret_values() do
        refute inspect(stored, limit: :infinity) =~ secret
      end
    end

    test "fails closed without a payload key", %{message: message} do
      original = Application.get_env(:simple_fit, Email)
      Application.put_env(:simple_fit, Email, Keyword.delete(original, :payload_key_base))
      on_exit(fn -> Application.put_env(:simple_fit, Email, original) end)

      assert Email.deliver_later(message) == {:error, :configuration_error}
      refute_enqueued(worker: DeliveryWorker)
    end
  end

  describe "DeliveryWorker" do
    test "delivers an enqueued email with a per-job idempotency key", %{message: message} do
      {:ok, %Oban.Job{id: id}} = Email.deliver_later(message)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :mailers)

      expected_key = "email-job-#{id}"
      assert_received {:email_delivered, ^message, [idempotency_key: ^expected_key]}
    end

    test "retries transient provider failures", %{message: message} do
      for reason <- [:timeout, :unavailable, :rate_limited] do
        Process.put(:email_error, reason)

        assert {:error, ^reason} =
                 perform_job(DeliveryWorker, sealed(message))
      end
    end

    test "cancels permanent failures instead of retrying", %{message: message} do
      for reason <- [:invalid_request, :unauthorized, :configuration_error] do
        Process.put(:email_error, reason)

        assert {:cancel, ^reason} =
                 perform_job(DeliveryWorker, sealed(message))
      end
    end

    test "cancels jobs whose payload cannot be opened or is no longer valid" do
      assert {:cancel, :invalid_request} = perform_job(DeliveryWorker, %{"payload" => "tampered"})
      assert {:cancel, :invalid_request} = perform_job(DeliveryWorker, %{"message" => %{}})

      {:ok, key_base} =
        Application.get_env(:simple_fit, Email) |> Keyword.fetch(:payload_key_base)

      invalid =
        Plug.Crypto.encrypt(key_base, "simplefit email job payload v1", %{"to" => "nope"},
          max_age: 60
        )

      assert {:cancel, :invalid_request} = perform_job(DeliveryWorker, %{"payload" => invalid})
    end
  end

  describe "JobPayload cryptography" do
    @salt "simplefit email job payload v1"

    defp key_base, do: Application.get_env(:simple_fit, Email)[:payload_key_base]

    test "uses authenticated XChaCha20-Poly1305 with a fresh random nonce per seal", %{
      message: message
    } do
      {:ok, a} = JobPayload.seal(message)
      {:ok, b} = JobPayload.seal(message)

      # Plug.Crypto.MessageEncryptor format: "XCP." <> base64url(nonce(24) <> tag(16) <> ciphertext).
      for sealed <- [a, b] do
        assert "XCP." <> encoded = sealed

        assert {:ok, <<_nonce::192, _tag::128, _ciphertext::binary>>} =
                 Base.url_decode64(encoded, padding: false)
      end

      refute a == b
      assert {:ok, ^message} = JobPayload.open(a)
      assert {:ok, ^message} = JobPayload.open(b)
    end

    test "any modified byte is rejected", %{message: message} do
      {:ok, "XCP." <> encoded} = JobPayload.seal(message)
      raw = Base.url_decode64!(encoded, padding: false)

      for position <- [0, 23, 24, 39, 40, byte_size(raw) - 1] do
        <<before::binary-size(^position), byte, rest::binary>> = raw

        tampered =
          "XCP." <>
            Base.url_encode64(<<before::binary, Bitwise.bxor(byte, 1), rest::binary>>,
              padding: false
            )

        assert JobPayload.open(tampered) == {:error, :invalid_request}
      end

      truncated =
        "XCP." <> Base.url_encode64(binary_part(raw, 0, byte_size(raw) - 1), padding: false)

      assert JobPayload.open(truncated) == {:error, :invalid_request}
    end

    test "payloads sealed under another key or salt do not open", %{message: message} do
      map = Message.to_map(message)
      other_key = String.duplicate("k", 64)

      assert JobPayload.open(Plug.Crypto.encrypt(other_key, @salt, map, max_age: 60)) ==
               {:error, :invalid_request}

      # Same SECRET_KEY_BASE, the session access-token salt: domain-separated keys.
      assert JobPayload.open(Plug.Crypto.encrypt(key_base(), "simplefit access token v1", map)) ==
               {:error, :invalid_request}
    end

    test "the 7-day lifetime is enforced by the reader, not by the payload", %{message: message} do
      map = Message.to_map(message)
      eight_days_ago = System.os_time(:second) - 8 * 24 * 60 * 60

      # A payload claiming a longer max_age is still rejected after 7 days.
      old =
        Plug.Crypto.encrypt(key_base(), @salt, map,
          signed_at: eight_days_ago,
          max_age: 365 * 86_400
        )

      assert JobPayload.open(old) == {:error, :invalid_request}

      six_days_ago = System.os_time(:second) - 6 * 24 * 60 * 60
      recent = Plug.Crypto.encrypt(key_base(), @salt, map, signed_at: six_days_ago, max_age: 1)
      assert {:ok, ^message} = JobPayload.open(recent)
    end

    test "sealing hides the plaintext and opening restores it exactly" do
      message = secret_message()
      map = Message.to_map(message)
      {:ok, sealed} = JobPayload.seal(message)
      raw = sealed |> String.trim_leading("XCP.") |> Base.url_decode64!(padding: false)

      # Never the plaintext representation itself.
      refute sealed == Jason.encode!(map)
      refute raw == :erlang.term_to_binary(map)
      refute sealed =~ "{"

      # The full sensitive values never appear, encoded or raw.
      for secret <- secret_values() do
        refute String.contains?(sealed, secret)
        assert :binary.match(raw, secret) == :nomatch
      end

      assert JobPayload.open(sealed) == {:ok, message}
    end

    test "rejects a key base shorter than 64 bytes", %{message: message} do
      original = Application.get_env(:simple_fit, Email)
      Application.put_env(:simple_fit, Email, Keyword.put(original, :payload_key_base, "short"))
      on_exit(fn -> Application.put_env(:simple_fit, Email, original) end)

      assert JobPayload.seal(message) == {:error, :configuration_error}
    end
  end
end
