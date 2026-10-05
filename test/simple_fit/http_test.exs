defmodule SimpleFit.HTTPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SimpleFit.HTTP

  describe "new/1" do
    test "fails fast and never retries or follows redirects by default" do
      request = HTTP.new(base_url: "https://provider.test")

      assert request.options.retry == false
      assert request.options.redirect == false
      assert request.options.receive_timeout == 15_000
      assert request.options.connect_options == [timeout: 5_000]
    end

    test "lets adapters override defaults" do
      request = HTTP.new(base_url: "https://provider.test", receive_timeout: 2_000)
      assert request.options.receive_timeout == 2_000
    end
  end

  describe "normalize/2" do
    test "returns 2xx responses unchanged" do
      response = %Req.Response{status: 201, body: %{"id" => "1"}}
      assert HTTP.normalize({:ok, response}, "test") == {:ok, response}
    end

    test "maps HTTP statuses to provider error reasons" do
      for {status, reason} <- [
            {400, :invalid_request},
            {401, :unauthorized},
            {403, :unauthorized},
            {404, :invalid_request},
            {408, :timeout},
            {409, :invalid_request},
            {422, :invalid_request},
            {429, :rate_limited},
            {500, :unavailable},
            {502, :unavailable},
            {503, :unavailable},
            {302, :unavailable}
          ] do
        capture_log(fn ->
          assert HTTP.normalize({:ok, %Req.Response{status: status}}, "test") == {:error, reason}
        end)
      end
    end

    test "maps transport failures" do
      capture_log(fn ->
        assert HTTP.normalize({:error, %Req.TransportError{reason: :timeout}}, "test") ==
                 {:error, :timeout}

        assert HTTP.normalize({:error, %Req.TransportError{reason: :econnrefused}}, "test") ==
                 {:error, :unavailable}
      end)
    end

    test "logs status and reason but never the response body" do
      response = %Req.Response{status: 422, body: %{"message" => "secret-provider-detail"}}

      log = capture_log(fn -> HTTP.normalize({:ok, response}, "test") end)

      assert log =~ "provider request failed"
      refute log =~ "secret-provider-detail"
    end
  end

  test "works offline through Req.Test stubs" do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"ok" => true}))

    result =
      [base_url: "https://provider.test", plug: {Req.Test, __MODULE__}]
      |> HTTP.new()
      |> Req.get(url: "/ping")
      |> HTTP.normalize("test")

    assert {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} = result
  end
end
