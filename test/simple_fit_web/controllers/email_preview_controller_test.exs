defmodule SimpleFitWeb.EmailPreviewControllerTest do
  # Not async: toggles the preview switch in the app env.
  use SimpleFitWeb.ConnCase, async: false

  alias SimpleFit.Email.Templates.{Fixtures, Inventory}

  defp previews(enabled) do
    original = Application.get_env(:simple_fit, :email_previews)
    Application.put_env(:simple_fit, :email_previews, enabled: enabled)

    on_exit(fn ->
      if original,
        do: Application.put_env(:simple_fit, :email_previews, original),
        else: Application.delete_env(:simple_fit, :email_previews)
    end)
  end

  test "is unreachable unless explicitly enabled (production and test default)" do
    assert Application.get_env(:simple_fit, :email_previews) == nil

    for path <- [
          "/dev/emails",
          "/dev/emails/E01",
          "/dev/emails/E01?format=text",
          "/dev/emails/E04?variant=no-progress"
        ] do
      conn = get(build_conn(), path)
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  test "is enabled only by config/dev.exs, never by runtime environment" do
    refute File.read!("config/runtime.exs") =~ "email_previews"
    refute File.read!("config/prod.exs") =~ "email_previews"
    assert File.read!("config/dev.exs") =~ "config :simple_fit, :email_previews, enabled: true"
  end

  test "lists every designed email with its status" do
    previews(true)
    conn = get(build_conn(), "/dev/emails")
    body = html_response(conn, 200)

    for entry <- Inventory.entries() do
      assert body =~ entry.id
      assert body =~ Plug.HTML.html_escape(entry.status)
    end

    assert body =~ "Version 63 · 1791284501-e3ff"
  end

  test "renders every implemented template with fixtures, as HTML and text" do
    previews(true)

    for entry <- Inventory.implemented() do
      html = build_conn() |> get("/dev/emails/#{entry.id}")
      assert html_response(html, 200) =~ "<!DOCTYPE html>"
      [csp] = get_resp_header(html, "content-security-policy")
      assert csp =~ "default-src 'none'"
      refute csp =~ "script-src"

      text = build_conn() |> get("/dev/emails/#{entry.id}?format=text")
      assert text.resp_body =~ "SimpleFit ·"
      assert ["text/plain" <> _] = get_resp_header(text, "content-type")
    end
  end

  test "all 16 designed emails are previewable, E04 and E10 included" do
    previews(true)
    assert length(Inventory.implemented()) == 16

    for id <- ["E04", "E10"] do
      assert html_response(get(build_conn(), "/dev/emails/#{id}"), 200) =~ "<!DOCTYPE html>"
    end

    assert json_response(get(build_conn(), "/dev/emails/nope"), 404)
    assert json_response(get(build_conn(), "/dev/emails/E17"), 404)
  end

  test "renders every named optional-state variant and rejects unknown ones" do
    previews(true)
    index = html_response(get(build_conn(), "/dev/emails"), 200)

    for %{id: id, template: template} <- Inventory.implemented(),
        variant <- Fixtures.variants(template) do
      assert index =~ "/dev/emails/#{id}?variant=#{variant}"
      assert html_response(get(build_conn(), "/dev/emails/#{id}?variant=#{variant}"), 200)
    end

    assert json_response(get(build_conn(), "/dev/emails/E04?variant=nope"), 404)
    assert json_response(get(build_conn(), "/dev/emails/E06?variant=minimal"), 404)
  end

  test "is not part of the OpenAPI contract" do
    spec = SimpleFitWeb.ApiSpec.spec()
    refute Enum.any?(Map.keys(spec.paths), &String.starts_with?(&1, "/dev"))
  end
end
