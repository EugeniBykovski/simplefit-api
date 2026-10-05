defmodule SimpleFit.EmailTest do
  use SimpleFit.DataCase, async: true
  use Oban.Testing, repo: SimpleFit.Repo

  alias SimpleFit.Email
  alias SimpleFit.Email.{DeliveryWorker, Message}

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

  describe "deliver_later/1" do
    test "enqueues the message in the mailers queue without sending it", %{message: message} do
      assert {:ok, %Oban.Job{}} = Email.deliver_later(message)

      assert_enqueued(
        worker: DeliveryWorker,
        queue: :mailers,
        args: %{"message" => Message.to_map(message)}
      )

      refute_received {:email_delivered, _, _}
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
                 perform_job(DeliveryWorker, %{"message" => Message.to_map(message)})
      end
    end

    test "cancels permanent failures instead of retrying", %{message: message} do
      for reason <- [:invalid_request, :unauthorized, :configuration_error] do
        Process.put(:email_error, reason)

        assert {:cancel, ^reason} =
                 perform_job(DeliveryWorker, %{"message" => Message.to_map(message)})
      end
    end

    test "cancels jobs whose stored message is no longer valid" do
      assert {:cancel, :invalid_request} =
               perform_job(DeliveryWorker, %{"message" => %{"to" => "nope"}})
    end
  end
end
