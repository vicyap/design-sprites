defmodule DesignSpriteWeb.ArtifactTest do
  use DesignSpriteWeb.ConnCase, async: false

  alias DesignSprite.{Artifacts, TestSupport}

  @html "<!doctype html><html><body><h1 id=\"hero\">Hello</h1></body></html>"

  test "the served artifact carries the inspector bridge; the stored bytes do not", %{conn: conn} do
    {:ok, 1} = Artifacts.write_new("index", @html, "ai")

    conn = get(conn, "/artifact/index")
    body = html_response(conn, 200)

    # The bridge: marker, click capture, stable descriptor, postMessage.
    assert body =~ "data-ds-inspector"
    assert body =~ "ds-element"
    assert body =~ "postMessage"
    assert body =~ "nth-of-type"
    assert body =~ "<h1 id=\"hero\">Hello</h1>"

    # Injection is serve-time only: history stays exactly as written.
    assert {:ok, stored} = DesignSprite.ProjectFiles.read("artifacts/index.html", 1)
    assert stored == @html
    refute stored =~ "data-ds-inspector"
  end

  test "a specific version serves its own bytes (snapshot v0 after a patch)", %{conn: conn} do
    {:ok, 0} = Artifacts.snapshot("legacy", @html, "human")
    {:ok, 1} = Artifacts.patch("legacy", "Hello", "Hi there", "ai")

    conn = get(conn, "/artifact/legacy/v/0")
    assert html_response(conn, 200) =~ "Hello"
    refute html_response(conn, 200) =~ "Hi there"

    conn = get(build_conn(), "/artifact/legacy")
    assert html_response(conn, 200) =~ "Hi there"
  end

  test "missing artifacts and versions are 404", %{conn: conn} do
    assert get(conn, "/artifact/nope").status == 404
    {:ok, 1} = Artifacts.write_new("index", @html, "ai")
    assert get(build_conn(), "/artifact/index/v/9").status == 404
  end

  test "an artifact that already contains the bridge is not double-injected", %{conn: _conn} do
    bridged = DesignSpriteWeb.ArtifactController.inject(@html, "index")
    assert DesignSpriteWeb.ArtifactController.inject(bridged, "index") == bridged
    assert length(String.split(bridged, "data-ds-inspector")) == 2
  end
end
