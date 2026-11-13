defmodule DesignSprite.AI.GatewayClientTest do
  @moduledoc """
  The gateway client against a local capture server speaking
  Anthropic-shaped SSE. These are the turn-timeout regression tests
  (2026-11-12 diagnosis, STATUS.md): the request must carry
  output_config effort "low" (the only thinking control the model
  accepts) and stream; a thinking-only response (stop_reason
  max_tokens, zero reply text — the thinking-burn signature) must be
  an ERROR, not a successful empty turn; a stalled connection must
  surface ONE visible error promptly, never the library's invisible
  retry multiplication.
  """
  use ExUnit.Case, async: false

  alias DesignSprite.AI.GatewayClient

  # ----------------------------------------------------------------
  # A minimal HTTP/1.1 capture server: one request per connection,
  # records bodies, replies through the responder fun.
  defmodule CaptureServer do
    def start(responder) do
      {:ok, agent} = Agent.start_link(fn -> %{connections: 0, requests: []} end)
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      pid = spawn(fn -> accept_loop(listen, agent, responder) end)
      {:ok, %{port: port, agent: agent, listen: listen, pid: pid}}
    end

    def stop(%{listen: listen, pid: pid}) do
      :gen_tcp.close(listen)
      Process.exit(pid, :kill)
      :ok
    end

    def state(%{agent: agent}), do: Agent.get(agent, & &1)

    defp accept_loop(listen, agent, responder) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          spawn(fn -> handle(socket, agent, responder) end)
          accept_loop(listen, agent, responder)

        {:error, _} ->
          :ok
      end
    end

    defp handle(socket, agent, responder) do
      case read_request(socket, "") do
        {:ok, body} ->
          Agent.update(agent, fn s ->
            %{s | connections: s.connections + 1, requests: s.requests ++ [body]}
          end)

          case responder.(body) do
            :stall -> Process.sleep(15_000)
            response when is_binary(response) -> :gen_tcp.send(socket, response)
          end

          :gen_tcp.close(socket)

        _ ->
          :gen_tcp.close(socket)
      end
    end

    defp read_request(socket, acc) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} ->
          acc = acc <> data

          case :binary.split(acc, "\r\n\r\n") do
            [head, rest] ->
              case content_length(head) do
                # No Content-Length: a bodyless request (e.g. GET) —
                # complete as soon as the headers are.
                nil -> {:ok, ""}
                length when byte_size(rest) >= length -> {:ok, binary_part(rest, 0, length)}
                _incomplete -> read_request(socket, acc)
              end

            _incomplete ->
              read_request(socket, acc)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp content_length(head) do
      head
      |> String.split("\r\n")
      |> Enum.find_value(fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(String.trim(name)) == "content-length" do
              case Integer.parse(String.trim(value)) do
                {n, _} -> n
                :error -> nil
              end
            end

          _ ->
            nil
        end
      end)
    end
  end

  # ----------------------------------------------------------------
  # SSE payloads (Anthropic Messages streaming shape)

  defp http_sse(events) do
    chunks =
      Enum.map_join(events, "", fn event ->
        "#{Integer.to_string(byte_size(event), 16)}\r\n#{event}\r\n"
      end)

    "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n" <>
      chunks <> "0\r\n\r\n"
  end

  defp sse(type, data), do: "event: #{type}\ndata: #{JSON.encode!(data)}\n\n"

  defp text_reply_events(text) do
    half = div(byte_size(text), 2)
    <<part1::binary-size(^half), part2::binary>> = text

    [
      sse("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-fable-5-2",
          "content" => [],
          "stop_reason" => nil,
          "usage" => %{"input_tokens" => 100, "output_tokens" => 1}
        }
      }),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => part1}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => part2}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 42}
      }),
      sse("message_stop", %{"type" => "message_stop"})
    ]
  end

  defp thinking_only_events do
    [
      sse("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-fable-5-2",
          "content" => [],
          "stop_reason" => nil,
          "usage" => %{"input_tokens" => 100, "output_tokens" => 1}
        }
      }),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "deliberating at length"}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "max_tokens", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 8192}
      }),
      sse("message_stop", %{"type" => "message_stop"})
    ]
  end

  @reply_json ~S|{"messages":["All set."],"actions":[],"score_judgements":[],"questions":[],"artifact":null,"artifact_patch":null,"model":null,"sharp":false,"questions_posted":0}|

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["messages"],
    "properties" => %{"messages" => %{"type" => "array", "items" => %{"type" => "string"}}}
  }

  setup do
    prev_url = Application.get_env(:design_sprite, :ai_gateway_url)
    prev_idle = Application.get_env(:design_sprite, :ai_stream_idle_timeout_ms)
    prev_backoff = Application.get_env(:design_sprite, :ai_retry_backoff_ms)
    # Retries are spaced by seconds in production (decorrelating
    # the model's draws); in tests the spacing is immaterial.
    Application.put_env(:design_sprite, :ai_retry_backoff_ms, 1)

    on_exit(fn ->
      restore_env(:ai_gateway_url, prev_url)
      restore_env(:ai_stream_idle_timeout_ms, prev_idle)
      restore_env(:ai_retry_backoff_ms, prev_backoff)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:design_sprite, key)
  defp restore_env(key, value), do: Application.put_env(:design_sprite, key, value)

  defp start_server(responder) do
    {:ok, server} = CaptureServer.start(responder)
    Application.put_env(:design_sprite, :ai_gateway_url, "http://127.0.0.1:#{server.port}")
    on_exit(fn -> CaptureServer.stop(server) end)
    server
  end

  test "streams the reply object and sends effort low on the request" do
    server = start_server(fn _body -> http_sse(text_reply_events(@reply_json)) end)

    assert {:ok, object} = GatewayClient.generate("system prompt", "the want", @schema)
    assert object["messages"] == ["All set."]
    assert object["questions_posted"] == 0

    %{connections: 1, requests: [body]} = CaptureServer.state(server)
    request = JSON.decode!(body)
    assert request["stream"] == true
    assert request["output_config"]["effort"] == "low"
    assert request["model"] == "claude-fable-5-2"
  end

  test "a thinking-only response is an error, never a successful empty turn" do
    server = start_server(fn _body -> http_sse(thinking_only_events()) end)

    assert {:error, {:ai_call_failed, :empty_object_response}} =
             GatewayClient.generate("system prompt", "the want", @schema)

    # The burn is stochastic per call, so generate retries it —
    # bounded at four attempts, then the error surfaces.
    assert CaptureServer.state(server).connections == 4
  end

  test "a call that burns empty once succeeds on a fresh retry attempt" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    server =
      start_server(fn _body ->
        n = Agent.get_and_update(calls, fn c -> {c + 1, c + 1} end)
        if n == 1, do: http_sse(thinking_only_events()), else: http_sse(text_reply_events(@reply_json))
      end)

    assert {:ok, object} = GatewayClient.generate("system prompt", "the want", @schema)
    assert object["messages"] == ["All set."]
    assert CaptureServer.state(server).connections == 2
  end

  # ----------------------------------------------------------------
  # Gateway discovery (the list call that resolves the base URL).
  # It runs lazily inside the first turn after a restart; a single
  # transient failure must not kill the turn or misreport itself as
  # "connection not found" (live incident 2026-11-12, see
  # GatewayClient moduledoc).

  defp http_json(status, object) do
    body = JSON.encode!(object)
    text = if status == 200, do: "OK", else: "Error"

    "HTTP/1.1 #{status} #{text}\r\ncontent-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n\r\n" <> body
  end

  defp start_list_server(responder) do
    {:ok, server} = CaptureServer.start(responder)
    Application.put_env(:design_sprite, :ai_gateway_list_url, "http://127.0.0.1:#{server.port}")
    Application.delete_env(:design_sprite, :ai_gateway_url)
    on_exit(fn -> CaptureServer.stop(server) end)
    server
  end

  setup do
    prev_list_url = Application.get_env(:design_sprite, :ai_gateway_list_url)
    on_exit(fn -> restore_env(:ai_gateway_list_url, prev_list_url) end)
    :ok
  end

  test "discovery retries a flaky list call and resolves the anthropic base URL" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    server =
      start_list_server(fn _body ->
        n = Agent.get_and_update(calls, fn c -> {c + 1, c + 1} end)

        if n < 3 do
          http_json(503, %{"error" => "busy"})
        else
          http_json(200, %{
            "connections" => [
              %{"provider" => "anthropic", "gateway_base_url" => "http://example.invalid/gw/"}
            ]
          })
        end
      end)

    assert {:ok, "http://example.invalid/gw"} = GatewayClient.gateway_base_url()
    assert CaptureServer.state(server).connections == 3
  end

  test "discovery reports not-found only when the list lacks an anthropic connection" do
    server =
      start_list_server(fn _body ->
        http_json(200, %{"connections" => [%{"provider" => "openai", "gateway_base_url" => "x"}]})
      end)

    assert {:error, :anthropic_gateway_connection_not_found} = GatewayClient.gateway_base_url()
    assert CaptureServer.state(server).connections == 3
  end

  test "discovery reports transport failure honestly after its retries" do
    server = start_list_server(fn _body -> http_json(503, %{"error" => "down"}) end)

    assert {:error, {:gateway_discovery_failed, {:http_status, 503}}} =
             GatewayClient.gateway_base_url()

    assert CaptureServer.state(server).connections == 3
  end

  test "a stalled connection surfaces one visible error after bounded attempts" do
    Application.put_env(:design_sprite, :ai_stream_idle_timeout_ms, 300)
    server = start_server(fn _body -> :stall end)

    started = System.monotonic_time(:millisecond)
    assert {:error, {:ai_call_failed, _reason}} = GatewayClient.generate("s", "u", @schema)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 10_000,
           "stalled call took #{elapsed}ms — each attempt must die at the idle timeout"

    # Exactly the bounded attempt count: the library's invisible
    # retry multiplication (max_retries default) is off, and the
    # client's own retries are four fresh connections, no more.
    assert CaptureServer.state(server).connections == 4,
           "expected exactly 4 connections (bounded attempts), got: " <>
             inspect(CaptureServer.state(server).connections)
  end
end
