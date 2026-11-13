defmodule DesignSpriteWeb.McpController do
  @moduledoc """
  MCP surface (contract item 1: external drivers get full parity via
  API/MCP). A deliberately thin JSON-RPC 2.0 skin over
  DesignSprite.Api — the same functions the REST controller calls, so
  there is exactly one implementation of every capability.

  Transport: one POST /mcp endpoint, Bearer admin token. Tools take a
  `driver_id` argument for mutations (the DriverLock lease, same as
  REST); reads need none.
  """
  use DesignSpriteWeb, :controller

  alias DesignSprite.Api
  alias DesignSpriteWeb.Auth

  plug :require_auth

  defp require_auth(conn, _opts) do
    if Auth.authorized?(conn), do: conn, else: Auth.unauthorized(conn)
  end

  @protocol "2025-03-26"

  def handle(conn, params) do
    id = params["id"]
    method = params["method"]
    rpc_params = params["params"] || %{}

    cond do
      # Notifications (no id) are acknowledged with no body.
      id == nil ->
        send_resp(conn, 202, "")

      true ->
        case dispatch(method, rpc_params) do
          {:result, result} -> rpc(conn, id, %{"result" => result})
          {:rpc_error, code, message} -> rpc(conn, id, %{"error" => %{"code" => code, "message" => message}})
        end
    end
  end

  defp rpc(conn, id, payload) do
    json(conn, Map.merge(%{"jsonrpc" => "2.0", "id" => id}, payload))
  end

  defp dispatch("initialize", params) do
    {:result,
     %{
       "protocolVersion" => params["protocolVersion"] || @protocol,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "design-sprite", "version" => "2.0.0"}
     }}
  end

  defp dispatch("ping", _params), do: {:result, %{}}

  defp dispatch("tools/list", _params) do
    {:result, %{"tools" => tools()}}
  end

  defp dispatch("tools/call", %{"name" => name, "arguments" => args}) do
    case call_tool(name, args || %{}) do
      {:ok, result} ->
        {:result,
         %{
           "content" => [%{"type" => "text", "text" => JSON.encode!(result)}],
           "isError" => false
         }}

      {:error, reason} ->
        {:result,
         %{
           "content" => [%{"type" => "text", "text" => JSON.encode!(%{"error" => to_string(reason)})}],
           "isError" => true
         }}
    end
  end

  defp dispatch("tools/call", _params), do: {:rpc_error, -32602, "invalid params"}

  defp dispatch(_method, _params), do: {:rpc_error, -32601, "method not found"}

  # ----------------------------------------------------------------
  # Tools — one per Api capability

  defp call_tool("get_state", _args), do: Api.state()
  defp call_tool("list_files", _args), do: Api.files()

  defp call_tool("read_file", args) do
    case Api.read_file(args["path"] || "", version_arg(args)) do
      {:ok, %{"bytes" => bytes} = result} ->
        {:ok, Map.put(result, "content", bytes) |> Map.delete("bytes")}

      {:error, _} = err ->
        err
    end
  end

  defp call_tool("export_bundle", _args) do
    case Api.export_bundle() do
      {:ok, zip, filename} ->
        {:ok,
         %{
           "filename" => filename,
           "content_type" => "application/zip",
           "base64" => Base.encode64(zip),
           "bytes" => byte_size(zip)
         }}

      {:error, _} = err ->
        err
    end
  end

  defp call_tool("acquire_driver", args), do: Api.acquire_driver(args["driver_id"])
  defp call_tool("heartbeat_driver", args), do: Api.heartbeat_driver(args["driver_id"])
  defp call_tool("release_driver", args), do: Api.release_driver(args["driver_id"])
  defp call_tool("create_project", args), do: Api.create_project(args["driver_id"], args["want"])
  defp call_tool("post_message", args), do: Api.post_message(args["driver_id"], args)

  defp call_tool("post_question", args),
    do: Api.post_question(args["driver_id"], args["question"] || args)

  defp call_tool("answer_question", args),
    do: Api.answer_question(args["driver_id"], args["key"], args)

  defp call_tool("skip_question", args),
    do: Api.skip_question(args["driver_id"], args["key"], args)

  defp call_tool("strike_question", args),
    do: Api.strike_question(args["driver_id"], args["key"], args)

  defp call_tool("judge_score", args), do: Api.judge_score(args["driver_id"], args["key"], args)
  defp call_tool("append_decision", args), do: Api.append_decision(args["driver_id"], args["text"])

  defp call_tool("write_artifact", args),
    do: Api.write_artifact(args["driver_id"], args["name"], args["html"])

  defp call_tool("patch_artifact", args),
    do: Api.patch_artifact(args["driver_id"], args["name"], args)

  defp call_tool("snapshot_artifact", args),
    do: Api.snapshot_artifact(args["driver_id"], args["name"], args["html"])

  defp call_tool("write_model", args), do: Api.write_model(args["driver_id"], args["text"])
  defp call_tool("declare_sharp", args), do: Api.declare_sharp(args["driver_id"])
  defp call_tool("resume", args), do: Api.resume(args["driver_id"])
  defp call_tool("commit_project", args), do: Api.commit(args["driver_id"])
  defp call_tool(_name, _args), do: {:error, :unknown_tool}

  defp version_arg(args) do
    case args["version"] do
      nil -> :latest
      "latest" -> :latest
      n when is_integer(n) and n >= 0 -> n
      _ -> :invalid
    end
  end

  # ----------------------------------------------------------------
  # Tool definitions

  defp obj(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => true
    }
  end

  defp str, do: %{"type" => "string"}
  defp driver_prop, do: %{"driver_id" => str()}

  defp tools do
    [
      %{"name" => "get_state", "description" => "The full Project state: project, verbatim entries, question views with scores, tally, files index, driver holder.", "inputSchema" => obj(%{}, [])},
      %{"name" => "list_files", "description" => "The exportable file set (exactly what the web explorer shows and the bundle contains).", "inputSchema" => obj(%{}, [])},
      %{"name" => "read_file", "description" => "Read one exportable file (transcript.md, record.json, model.md, artifacts/...), latest or a specific version.", "inputSchema" => obj(%{"path" => str(), "version" => %{"type" => "integer"}}, ["path"])},
      %{"name" => "export_bundle", "description" => "The deliverable as a zip (base64): latest model + artifacts + transcript + record, plus full version history.", "inputSchema" => obj(%{}, [])},
      %{"name" => "acquire_driver", "description" => "Take the one-Driver lease (required before any mutation).", "inputSchema" => obj(driver_prop(), ["driver_id"])},
      %{"name" => "heartbeat_driver", "description" => "Refresh your Driver lease.", "inputSchema" => obj(driver_prop(), ["driver_id"])},
      %{"name" => "release_driver", "description" => "Give up the Driver lease.", "inputSchema" => obj(driver_prop(), ["driver_id"])},
      %{"name" => "create_project", "description" => "Create the Project from the opening want (only when none exists).", "inputSchema" => obj(Map.merge(driver_prop(), %{"want" => str()}), ["driver_id", "want"])},
      %{"name" => "post_message", "description" => "Post a chat message. actor: agent (you are driving) or human (relayed human words; kicks the built-in AI). elements: optional inspector attachments.", "inputSchema" => obj(Map.merge(driver_prop(), %{"text" => str(), "actor" => str(), "elements" => %{"type" => "array"}}), ["driver_id", "text"])},
      %{"name" => "post_question", "description" => "Post a question card (same validation as the built-in AI's cards). Pass the question fields directly or under question.", "inputSchema" => obj(driver_prop(), ["driver_id"])},
      %{"name" => "answer_question", "description" => "Answer a question: choice (single/preview), choices (multi), other_text, dialed_value (preview, verbatim), comment. actor defaults to human (kicks the built-in AI).", "inputSchema" => obj(Map.merge(driver_prop(), %{"key" => str(), "choice" => str(), "choices" => %{"type" => "array"}, "other_text" => str(), "dialed_value" => str(), "comment" => str(), "actor" => str()}), ["driver_id", "key"])},
      %{"name" => "skip_question", "description" => "Skip a question; the prediction stands, no score.", "inputSchema" => obj(Map.merge(driver_prop(), %{"key" => str(), "note" => str()}), ["driver_id", "key"])},
      %{"name" => "strike_question", "description" => "Strike a question: 'out of scope' — the axis is removed, terminal.", "inputSchema" => obj(Map.merge(driver_prop(), %{"key" => str(), "note" => str()}), ["driver_id", "key"])},
      %{"name" => "judge_score", "description" => "Append a superseding score for a provisional (comment-carrying) answer: result hit|miss with a reason.", "inputSchema" => obj(Map.merge(driver_prop(), %{"key" => str(), "result" => str(), "reason" => str()}), ["driver_id", "key", "result", "reason"])},
      %{"name" => "append_decision", "description" => "Append to the Decided-for-you log. Works after Commit (the one post-Commit write).", "inputSchema" => obj(Map.merge(driver_prop(), %{"text" => str()}), ["driver_id", "text"])},
      %{"name" => "write_artifact", "description" => "Write a full artifact version (first generation or an explicitly requested new direction).", "inputSchema" => obj(Map.merge(driver_prop(), %{"name" => str(), "html" => str()}), ["driver_id", "name", "html"])},
      %{"name" => "patch_artifact", "description" => "Patch an artifact into a new version: find must occur exactly once in the current bytes. element optionally names the inspector target.", "inputSchema" => obj(Map.merge(driver_prop(), %{"name" => str(), "find" => str(), "replace" => str(), "element" => str()}), ["driver_id", "name", "find", "replace"])},
      %{"name" => "snapshot_artifact", "description" => "Enter an existing page's HTML as artifact version 0 (new artifact names only).", "inputSchema" => obj(Map.merge(driver_prop(), %{"name" => str(), "html" => str()}), ["driver_id", "name", "html"])},
      %{"name" => "write_model", "description" => "Write a new model.md version (the re-derived decision model).", "inputSchema" => obj(Map.merge(driver_prop(), %{"text" => str()}), ["driver_id", "text"])},
      %{"name" => "declare_sharp", "description" => "Declare the model sharp — only lands when the deterministic sharpness gate passes.", "inputSchema" => obj(driver_prop(), ["driver_id"])},
      %{"name" => "resume", "description" => "The human's 'keep asking': reopen the frontier after a sharpness declaration.", "inputSchema" => obj(driver_prop(), ["driver_id"])},
      %{"name" => "commit_project", "description" => "Commit: freeze the deliverable, lock the Project read-only (Decided-for-you stays appendable).", "inputSchema" => obj(driver_prop(), ["driver_id"])}
    ]
  end
end
