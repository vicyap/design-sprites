defmodule DesignSpriteWeb.ApiTest do
  use DesignSpriteWeb.ConnCase, async: false

  test "health does a real DB round trip", %{conn: conn} do
    conn = get(conn, "/health")
    body = json_response(conn, 200)
    assert body["ok"] == true
    assert body["app"] == "design_sprite"
  end

  test "the page's importmap points at assets that actually serve", %{conn: conn} do
    # Regression guard for the two v1 fleet asset bugs (2026-11-11):
    # a wrong ESM filename (404) and a window.LiveSocket guard.
    conn = get(conn, "/")
    html = html_response(conn, 200)

    assert html =~ "/assets/phoenix.mjs"
    assert html =~ "/assets/phoenix_live_view.esm.js"
    refute html =~ "phoenix.esm.js"

    for asset <- ["phoenix.mjs", "phoenix_live_view.esm.js"] do
      c = get(build_conn(), "/assets/" <> asset)
      assert c.status == 200, "expected /assets/#{asset} to serve, got #{c.status}"
      assert byte_size(c.resp_body) > 1_000
    end

    c = get(build_conn(), "/app.js")
    assert c.status == 200
    assert c.resp_body =~ "longPollFallbackMs"

    app_js =
      :design_sprite
      |> Application.app_dir("priv/static/app.js")
      |> File.read!()

    assert app_js =~ ~s(import { LiveSocket } from "phoenix_live_view")
    assert app_js =~ "liveSocket.connect()"
    refute app_js =~ "window.LiveSocket"
  end
end
