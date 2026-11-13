defmodule DesignSpriteWeb.ProjectApiTest do
  @moduledoc """
  Phase 4: the REST + MCP skins over DesignSprite.Api — auth, the
  Driver lease over HTTP, a full turn driven purely over the API,
  file/export reads, and MCP round trips.
  """
  use DesignSpriteWeb.ConnCase, async: false

  alias DesignSprite.{Record, TestSupport}

  @driver "rest-driver"

  defp acquire(conn) do
    conn
    |> TestSupport.authed()
    |> put_req_header("x-driver-id", @driver)
    |> post("/api/driver/acquire", %{"driver_id" => @driver})
  end

  defp as_driver(conn) do
    conn
    |> TestSupport.authed()
    |> put_req_header("x-driver-id", @driver)
  end

  test "the API refuses requests without the Bearer token", %{conn: conn} do
    conn = get(conn, "/api/state")
    assert json_response(conn, 401)["error"] == "unauthorized"

    conn = post(build_conn(), "/api/driver/acquire", %{"driver_id" => @driver})
    assert json_response(conn, 401)

    conn = post(build_conn(), "/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    assert json_response(conn, 401)
  end

  test "a full turn driven purely over the REST API", %{conn: conn} do
    conn = acquire(conn)
    assert json_response(conn, 200)["driver"] == @driver

    conn =
      as_driver(build_conn())
      |> post("/api/project", %{"want" => "Design a settings page"})

    assert json_response(conn, 200)["project"]["status"] == "open"

    conn =
      as_driver(build_conn())
      |> post("/api/questions", %{"question" => TestSupport.question("layout")})

    assert json_response(conn, 200)["entry"]["kind"] == "question"

    conn =
      as_driver(build_conn())
      |> post("/api/questions/layout/answer", %{"choice" => "alpha", "actor" => "agent"})

    body = json_response(conn, 200)
    assert body["score"]["payload"]["result"] == "hit"
    assert Record.question_view("layout").state == :answered

    # Reads: state, files, file content, bundle — same token, no lease.
    conn = TestSupport.authed(build_conn()) |> get("/api/state")
    state = json_response(conn, 200)
    assert state["tally"]["hits"] == 1
    assert state["driver"] == @driver

    conn = TestSupport.authed(build_conn()) |> get("/api/files")
    paths = Enum.map(json_response(conn, 200)["files"], & &1["path"])
    assert "transcript.md" in paths
    assert "record.json" in paths

    conn =
      as_driver(build_conn())
      |> post("/api/model", %{"text" => "# Model\n- Layout: alpha."})

    assert json_response(conn, 200)["version"] == 1

    conn = TestSupport.authed(build_conn()) |> get("/api/files/content", %{"path" => "model.md"})
    assert response(conn, 200) =~ "Layout: alpha"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/markdown"

    conn = TestSupport.authed(build_conn()) |> get("/api/export")
    assert response(conn, 200) |> binary_part(0, 2) == "PK"
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"

    # Commit over the API; the lock then refuses design writes but
    # still takes a Decided-for-you append.
    conn = as_driver(build_conn()) |> post("/api/commit", %{})
    assert json_response(conn, 200)["project"]["status"] == "committed"

    conn =
      as_driver(build_conn())
      |> post("/api/messages", %{"text" => "too late", "actor" => "agent"})

    assert json_response(conn, 409)["error"] == "committed"

    conn =
      as_driver(build_conn())
      |> post("/api/decisions", %{"text" => "Shipped per the model."})

    assert json_response(conn, 200)["entry"]["kind"] == "decision"

    conn = as_driver(build_conn()) |> post("/api/driver/release", %{})
    assert json_response(conn, 200)["ok"] == true
  end

  test "driver conflicts surface as 409 over HTTP", %{conn: conn} do
    conn = acquire(conn)
    assert json_response(conn, 200)

    conn =
      build_conn()
      |> TestSupport.authed()
      |> put_req_header("x-driver-id", "someone-else")
      |> post("/api/messages", %{"text" => "let me in", "actor" => "agent"})

    assert json_response(conn, 409)["error"] == "driver_held"

    conn = as_driver(build_conn()) |> post("/api/driver/release", %{})
    assert json_response(conn, 200)
  end

  test "MCP: initialize, tools/list, and a tools/call round trip", %{conn: conn} do
    rpc = fn conn, payload ->
      conn |> TestSupport.authed() |> post("/mcp", payload)
    end

    conn =
      rpc.(build_conn(), %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-03-26"}
      })

    body = json_response(conn, 200)
    assert body["result"]["serverInfo"]["name"] == "design-sprite"
    assert body["result"]["protocolVersion"] == "2025-03-26"

    conn = rpc.(build_conn(), %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
    tools = json_response(conn, 200)["result"]["tools"]
    names = Enum.map(tools, & &1["name"])
    assert "answer_question" in names
    assert "commit_project" in names
    assert "export_bundle" in names
    assert length(names) == 22

    call = fn name, args ->
      rpc.(build_conn(), %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      })
      |> json_response(200)
    end

    result = call.("acquire_driver", %{"driver_id" => "mcp-driver"})
    assert result["result"]["isError"] == false

    result = call.("create_project", %{"driver_id" => "mcp-driver", "want" => "Design a help page"})
    assert result["result"]["isError"] == false

    result = call.("get_state", %{})
    text = hd(result["result"]["content"])["text"]
    state = JSON.decode!(text)
    assert state["project"]["want"] == "Design a help page"

    # A mutation from a non-holder is an MCP tool error, not a crash.
    result = call.("post_message", %{"driver_id" => "intruder", "text" => "hi", "actor" => "agent"})
    assert result["result"]["isError"] == true
    assert hd(result["result"]["content"])["text"] =~ "driver_held"

    result = call.("release_driver", %{"driver_id" => "mcp-driver"})
    assert result["result"]["isError"] == false

    conn = rpc.(build_conn(), %{"jsonrpc" => "2.0", "id" => 9, "method" => "nope/nope"})
    assert json_response(conn, 200)["error"]["code"] == -32601
  end
end
