defmodule SimpleFit.Storage.S3Test do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SimpleFit.Storage.S3

  @now ~U[2026-10-05 12:00:00Z]
  @config [
    bucket: "simplefit-media",
    region: "eu-central-1",
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  ]

  defp upload_request(overrides \\ %{}) do
    Map.merge(
      %{
        method: :put,
        key: "avatars/u1/original.jpg",
        headers: %{"content-type" => "image/jpeg", "content-length" => "48213"},
        expires_in: 900,
        now: @now
      },
      overrides
    )
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  test "presigns a virtual-hosted S3 upload with content type and length signed" do
    assert {:ok, presigned} = S3.presign(upload_request(), @config)

    uri = URI.parse(presigned.url)
    assert uri.scheme == "https"
    assert uri.host == "simplefit-media.s3.eu-central-1.amazonaws.com"
    assert uri.path == "/avatars/u1/original.jpg"

    params = query(presigned.url)
    assert params["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert params["X-Amz-Credential"] == "AKIDEXAMPLE/20261005/eu-central-1/s3/aws4_request"
    assert params["X-Amz-Date"] == "20261005T120000Z"
    assert params["X-Amz-Expires"] == "900"
    assert params["X-Amz-SignedHeaders"] == "content-length;content-type;host"
    assert params["X-Amz-Signature"] =~ ~r/\A[0-9a-f]{64}\z/

    assert presigned.method == :put
    assert presigned.headers == %{"content-type" => "image/jpeg", "content-length" => "48213"}
    assert presigned.expires_at == ~U[2026-10-05 12:15:00Z]
  end

  test "is deterministic and the signature depends on the signed headers" do
    {:ok, a} = S3.presign(upload_request(), @config)
    {:ok, b} = S3.presign(upload_request(), @config)

    {:ok, c} =
      S3.presign(
        upload_request(%{headers: %{"content-type" => "image/png", "content-length" => "48213"}}),
        @config
      )

    assert a.url == b.url
    refute query(a.url)["X-Amz-Signature"] == query(c.url)["X-Amz-Signature"]
  end

  test "never puts the secret key in the URL" do
    {:ok, presigned} = S3.presign(upload_request(), @config)
    refute presigned.url =~ "wJalrXUtnFEMI"
  end

  test "includes the session token for temporary credentials" do
    {:ok, presigned} =
      S3.presign(upload_request(), Keyword.put(@config, :session_token, "FQoGZXIvYXdzEXAMPLE"))

    assert query(presigned.url)["X-Amz-Security-Token"] == "FQoGZXIvYXdzEXAMPLE"
  end

  test "applies the environment key prefix and supports S3-compatible endpoints (path style)" do
    config = Keyword.merge(@config, endpoint: "http://localhost:9000/", key_prefix: "dev/")
    {:ok, presigned} = S3.presign(upload_request(%{method: :get, headers: %{}}), config)

    uri = URI.parse(presigned.url)
    assert {uri.scheme, uri.host, uri.port} == {"http", "localhost", 9000}
    assert uri.path == "/simplefit-media/dev/avatars/u1/original.jpg"
    assert query(presigned.url)["X-Amz-SignedHeaders"] == "host"
  end

  test "fails closed without logging credentials when configuration is missing" do
    for missing <- [:bucket, :region, :access_key_id, :secret_access_key] do
      log =
        capture_log(fn ->
          assert S3.presign(upload_request(), Keyword.delete(@config, missing)) ==
                   {:error, :configuration_error}
        end)

      assert log =~ "storage is not configured"
      refute log =~ "wJalrXUtnFEMI"
    end

    capture_log(fn ->
      assert S3.presign(upload_request(), Keyword.put(@config, :bucket, "")) ==
               {:error, :configuration_error}
    end)
  end

  # Pins the SigV4 presigning of our HTTP client to AWS's published example
  # (https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html),
  # so a dependency upgrade that changes the signature fails here.
  test "Req SigV4 presigning matches the AWS reference example" do
    url =
      Req.Utils.aws_sigv4_url(
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        service: :s3,
        datetime: ~U[2013-05-24 00:00:00Z],
        method: :get,
        url: "https://examplebucket.s3.amazonaws.com/test.txt",
        expires: 86_400
      )

    assert query(to_string(url))["X-Amz-Signature"] ==
             "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end
end
