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
end
