defmodule SimpleFit.StorageTest do
  use ExUnit.Case, async: true

  alias SimpleFit.Storage
  alias SimpleFit.Storage.Presigned

  @now ~U[2026-10-05 12:00:00Z]

  describe "presign_upload/2" do
    test "signs content type and exact length for a direct upload (fake adapter in test)" do
      assert {:ok, %Presigned{} = upload} =
               Storage.presign_upload("avatars/u1/original.jpg",
                 content_type: "image/jpeg",
                 content_length: 48_213,
                 now: @now
               )

      assert upload.method == :put
      assert upload.headers == %{"content-type" => "image/jpeg", "content-length" => "48213"}
      assert upload.expires_at == ~U[2026-10-05 12:15:00Z]
      assert upload.url =~ "https://fake-storage.invalid/simplefit-test/avatars/u1/original.jpg"
    end

    test "rejects invalid keys and options" do
      valid = [content_type: "image/jpeg", content_length: 10]

      for {key, opts} <- [
            {"../etc/passwd", valid},
            {"ok/key", Keyword.delete(valid, :content_type)},
            {"ok/key", Keyword.put(valid, :content_type, "image/jpeg\r\nx-injected: 1")},
            {"ok/key", Keyword.put(valid, :content_type, "not a type")},
            {"ok/key", Keyword.put(valid, :content_length, 0)},
            {"ok/key", Keyword.put(valid, :content_length, 5 * 1024 * 1024 * 1024 + 1)},
            {"ok/key", Keyword.put(valid, :expires_in, 3_601)},
            {"ok/key", Keyword.put(valid, :expires_in, 0)}
          ] do
        assert Storage.presign_upload(key, opts) == {:error, :invalid_request},
               inspect({key, opts})
      end
    end
  end

  describe "presign_download/2" do
    test "presigns a short-lived private download" do
      assert {:ok, download} = Storage.presign_download("documents/d1/contract.pdf", now: @now)
      assert download.method == :get
      assert download.headers == %{}
      assert download.expires_at == ~U[2026-10-05 12:05:00Z]
    end
  end

  test "never prints signed URLs when inspected (e.g. in logs)" do
    {:ok, download} = Storage.presign_download("documents/d1/contract.pdf")
    refute inspect(download) =~ "fake-storage.invalid"
    refute inspect(download) =~ "url:"
  end

  test "emits telemetry with adapter and result, not the key or URL" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:simple_fit, :storage, :presign, :stop]])

    {:ok, _download} = Storage.presign_download("documents/d1/contract.pdf")

    assert_received {[:simple_fit, :storage, :presign, :stop], ^ref, %{duration: _},
                     %{adapter: SimpleFit.Storage.Fake, method: :get, result: :ok} = metadata}

    refute Map.has_key?(metadata, :key)
  end

  describe "stat/2 and delete/2 (SF-103)" do
    test "a presigned HEAD reads the stored size and type; missing objects are not found" do
      Req.Test.stub(SimpleFit.Storage, fn conn ->
        assert conn.method == "HEAD"
        assert conn.host == "fake-storage.invalid"
        assert conn.request_path == "/simplefit-test/documents/d1/contract.pdf"
        assert conn.query_string =~ "method=head"

        conn
        |> Plug.Conn.put_resp_header("content-length", "2048")
        |> Plug.Conn.put_resp_header("content-type", "application/pdf")
        |> Plug.Conn.send_resp(200, "")
      end)

      assert Storage.stat("documents/d1/contract.pdf") ==
               {:ok, %{content_length: 2048, content_type: "application/pdf"}}

      for status <- [403, 404] do
        Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, status, ""))
        assert Storage.stat("documents/d1/contract.pdf") == {:error, :not_found}
      end

      Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, 503, ""))

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Storage.stat("documents/d1/contract.pdf") == {:error, :unavailable}
             end) =~ "provider request failed"

      assert Storage.stat("../etc/passwd") == {:error, :invalid_request}
    end

    test "a presigned DELETE removes an object; an absent one is already gone" do
      test_pid = self()

      Req.Test.stub(SimpleFit.Storage, fn conn ->
        send(test_pid, {:method, conn.method})
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert Storage.delete("documents/d1/contract.pdf") == :ok
      assert_received {:method, "DELETE"}

      Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, 404, ""))
      assert Storage.delete("documents/d1/contract.pdf") == :ok

      Req.Test.stub(SimpleFit.Storage, &Plug.Conn.send_resp(&1, 401, ""))

      ExUnit.CaptureLog.capture_log(fn ->
        assert Storage.delete("documents/d1/contract.pdf") == {:error, :unauthorized}
      end)
    end
  end
end
