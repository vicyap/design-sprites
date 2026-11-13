defmodule DesignSprite.CommitLockTest do
  @moduledoc """
  Phase 4 lock semantics: the Commit freeze holds at EVERY layer —
  the record (Phase 1) and now the file storage layer too, so no
  surface (web, API, driver) can write design content into a
  committed Project — while Decided-for-you stays appendable, and
  the Commit webhook fires fire-and-forget.
  """
  use ExUnit.Case, async: false

  alias DesignSprite.{Artifacts, ProjectFiles, Record, TestSupport}

  setup do
    TestSupport.wipe!()
    {:ok, _} = Record.create_project("Design a settings page")
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))
    {:ok, 1} = Artifacts.write_new("index", "<html><body><p>hi</p></body></html>", "ai")
    :ok
  end

  test "after Commit, file writes of every flavour are refused" do
    assert {:ok, _} = Record.commit("human")

    assert {:error, :committed} = ProjectFiles.write("model.md", "# new model", "ai")
    assert {:error, :committed} = ProjectFiles.write_at("notes.md", "x", "agent", 1)
    assert {:error, :committed} = Artifacts.write_new("index", "<html>v2</html>", "agent")
    assert {:error, :committed} = Artifacts.patch("index", "hi", "bye", "agent")
    assert {:error, :committed} = Artifacts.snapshot("other", "<html></html>", "agent")
    assert {:error, :committed} = Record.snapshot_artifact("other", "<html></html>", "agent")

    # History is untouched: the pre-Commit bytes are still the latest.
    assert Artifacts.current_html("index") =~ "hi"
    assert Artifacts.current_version("index") == 1
  end

  test "after Commit, record writes are refused except decision/system" do
    assert {:ok, _} = Record.commit("human")

    assert {:error, :committed} = Record.post_message("human", "more")
    assert {:error, :committed} = Record.post_question("agent", TestSupport.question("more"))
    assert {:error, :committed} = Record.answer_question("layout", %{"choice" => "alpha"}, "human")
    assert {:error, :committed} = Record.skip_question("layout", "human")
    assert {:error, :committed} = Record.strike_question("layout", "human")
    assert {:error, :committed} = Record.supersede_score("layout", "hit", "x", "agent")

    # The exception: the implementing agent's Decided-for-you log.
    assert {:ok, entry} = Record.append_decision("agent", "Implemented layout as alpha per model v1.")
    assert entry.kind == "decision"
    assert {:error, :already_committed} = Record.commit("agent")
  end

  test "the webhook fires on Commit with ids only, Bearer when configured" do
    {:ok, capture} = start_capture()
    port = capture.port

    on_exit(fn ->
      Application.delete_env(:design_sprite, :webhook_url)
      Application.delete_env(:design_sprite, :webhook_token)
    end)

    Application.put_env(:design_sprite, :webhook_url, "http://127.0.0.1:#{port}/hook")
    Application.put_env(:design_sprite, :webhook_token, "wh-token")

    assert {:ok, _} = Record.commit("human")

    assert_receive {:webhook_request, request}, 3_000
    assert request =~ "POST /hook"
    assert request =~ "authorization: Bearer wh-token"
    assert request =~ ~s("event":"project.committed")
    # ids + timestamps only: the want text must NOT ride along.
    refute request =~ "settings page"

    stop_capture(capture)
  end

  test "a dead webhook target never blocks or fails the Commit" do
    on_exit(fn -> Application.delete_env(:design_sprite, :webhook_url) end)
    Application.put_env(:design_sprite, :webhook_url, "http://127.0.0.1:1/hook")

    assert {:ok, project} = Record.commit("human")
    assert project.status == "committed"
    # Give the fire-and-forget task its moment; the Commit already landed.
    Process.sleep(150)
    assert Record.committed?()
  end

  # A one-shot TCP capture server: accepts one connection, reads the
  # request, replies 200, and reports the raw request to the test.
  defp start_capture do
    test_pid = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        {:ok, request} = read_request(socket, "")
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n{}")
        :gen_tcp.close(socket)
        send(test_pid, {:webhook_request, request})
      end)

    {:ok, %{port: port, listen: listen, task: task}}
  end

  defp stop_capture(%{listen: listen, task: task}) do
    :gen_tcp.close(listen)
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") and body_complete?(acc) do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> read_request(socket, acc <> data)
        _ -> {:ok, acc}
      end
    end
  end

  defp body_complete?(acc) do
    case Regex.run(~r/content-length: (\d+)/i, acc) do
      [_, len] ->
        case String.split(acc, "\r\n\r\n", parts: 2) do
          [_, body] -> byte_size(body) >= String.to_integer(len)
          _ -> false
        end

      _ ->
        true
    end
  end
end
