defmodule DesignSpriteWeb.ExplorerTest do
  @moduledoc """
  Phase 4: the web file explorer shows exactly the exportable set,
  file views are version-aware, and the download routes serve the
  same bytes the API hands an implementing agent.
  """
  use DesignSpriteWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DesignSprite.{Artifacts, ProjectFiles, Record}

  setup %{conn: _conn} do
    {:ok, _} = Record.create_project("Design a settings page")
    {:ok, 1} = ProjectFiles.write("model.md", "# Model v1", "ai")
    {:ok, _} = Record.append("model", "ai", nil, %{"path" => "model.md", "version" => 1})
    {:ok, 2} = ProjectFiles.write("model.md", "# Model v2", "ai")
    {:ok, _} = Record.append("model", "ai", nil, %{"path" => "model.md", "version" => 2})
    {:ok, 1} = Artifacts.write_new("index", "<html><body><h1>Hi</h1></body></html>", "ai")
    {:ok, _} = Record.append_artifact_entry("index", 1, "ai")
    :ok
  end

  test "the explorer lists exactly the exportable set, with a bundle download", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view |> element("button", "File explorer") |> render_click()
    html = render(view)

    assert html =~ "What gets exported"
    assert html =~ "transcript.md"
    assert html =~ "record.json"
    assert html =~ "model.md"
    assert html =~ "artifacts/index.html"
    assert html =~ "live projection of the record"
    assert html =~ "v2 · 2 versions"
    assert html =~ "/export"
  end

  test "a file view is version-aware: old versions render and are labelled history", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view |> element("button", "File explorer") |> render_click()
    view |> element(".explorer-row button[phx-value-path='model.md']") |> render_click()
    html = render(view)
    assert html =~ "Model v2"
    assert html =~ "v1"
    assert html =~ "v2 · latest"

    view
    |> element("button.version-chip", "v1")
    |> render_click()

    html = render(view)
    assert html =~ "Model v1"
    assert html =~ "history is kept"
  end

  test "the bundle and raw downloads serve the deliverable bytes", %{conn: conn} do
    conn = get(conn, "/export")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "design-sprite-"

    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    names = Enum.map(files, &to_string(elem(&1, 0)))
    assert "model.md" in names
    assert "history/model.md/v1" in names
    assert "transcript.md" in names
    assert "record.json" in names

    conn = get(build_conn(), "/files/raw", %{"path" => "model.md", "version" => "1"})
    assert response(conn, 200) == "# Model v1"

    # The raw artifact download is the pristine stored bytes — the
    # inspector bridge is a serve-time injection on /artifact only.
    conn = get(build_conn(), "/files/raw", %{"path" => "artifacts/index.html"})
    assert response(conn, 200) == "<html><body><h1>Hi</h1></body></html>"

    conn = get(build_conn(), "/files/raw", %{"path" => "../app.db"})
    assert conn.status == 404

    conn = get(build_conn(), "/files/raw", %{"path" => "transcript.md"})
    assert response(conn, 200) =~ "Design a settings page"
  end
end
