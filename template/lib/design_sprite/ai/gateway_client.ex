defmodule DesignSprite.AI.GatewayClient do
  @moduledoc """
  The AI driver over the Sprites gateway's conn:anthropic connection,
  via ReqLLM's streaming structured-output call (`stream_object`);
  the driver still validates semantics before applying the reply.

  Gateway mechanics (proven 2026-11-11 by the advisor consult scripts):
  - The sprite carries the label `conn:anthropic`; the gateway injects
    the credentials — NO keys ever live in the sprite. ReqLLM requires
    an api_key value to build the request, so a placeholder is passed;
    the gateway replaces/ignores it (this is verified live in Phase 1).
  - The connection's base URL is discovered from inside the sprite via
    GET https://api.sprites.dev/v1/gateway/list (provider "anthropic").
    AI_GATEWAY_URL overrides discovery with a pinned base URL.
  - The configured model id is registered with LLMDB as a custom
    overlay in runtime.exs — gateway-only ids like claude-fable-5-2
    are not in LLMDB's packaged catalog and Model resolution raises
    for unregistered ids.

  Turn-timeout diagnosis (2026-11-12, measured in-sprite on the pilot
  Project; full record in STATUS.md): the model is an ADAPTIVE-thinking
  model. At the default effort it deliberated past the driver's whole
  8,192-token output budget without emitting any reply text — raw
  responses came back stop_reason "max_tokens", out_tok 8192, content
  blocks ["thinking"] only, text_bytes 0, twice (structured + plain).
  Legacy thinking controls are rejected by the provider (400: use
  "thinking.type.adaptive" and "output_config.effort"). Consequences
  that made this a silent stall instead of a slow turn:
  - burning 8,192 thinking tokens takes ~110–120s at the measured
    ~65–75 tok/s, straddling the old 120s non-streaming receive
    timeout: attempts alternated between returning an EMPTY object
    (a fake success the driver applied as a no-op) and timing out;
  - ReqLLM's default step retries a :timeout instantly, up to 3
    times, so one logical call could regenerate invisibly for ~8
    minutes — the driver's 150s cap then reported turn_timeout and
    no ai.call error ever surfaced.
  The fixes, at this layer:
  - `output_config: %{effort: "low"}` — the one control the provider
    accepts; at low the same request completed properly (end_turn,
    full reply text) in ~109s.
  - STREAMING transport: chunks (thinking + text) flow from ~3s, so
    progress is continuous and no single response wait can cliff;
    the timeout that remains is an IDLE timeout — silence between
    chunks — which is a stall detector, not a latency cliff.
  - `max_retries: 0`: a failed call returns ONE visible error to the
    driver; retrying is the driver's visible business, never the
    library's invisible one.
  - An empty/absent reply object (the max_tokens-burn signature) is
    an ERROR ({:error, {:ai_call_failed, :empty_object_response}}),
    never a successful empty turn.
  - ai.call now emits on success too, with duration_ms and the chunk
    count — latency is a measured field, not a post-mortem (D21's
    direction: metadata, never content).
  - Effort "low" REDUCES the deliberation; it does not bound it —
    proven live 2026-11-12 after the streaming switch, by raw and
    ReqLLM calls alike, on both transports: the identical payload
    completed once with 1,856 thinking tokens and an 11.7KB reply
    (end_turn, 53s), and burned to the 8,192-token cap with zero
    reply text on other draws (stop_reason max_tokens). The burn
    is a per-call stochastic outcome of the model's adaptive
    thinking on this context, so the call layer retries it:
    generate/3 makes up to four attempts, each a FRESH streaming
    call on a fresh connection, spaced by a growing pause (the
    draws are time-correlated — three back-to-back attempts once
    burned identically at ~83s), each emitting its own ai.call
    line with its attempt number — bounded, visible, and never
    applied to the record until a full reply object exists. (This
    is the app layer's own retry; the library's invisible one
    stays off.)
  """

  @behaviour DesignSprite.AI.Client

  alias DesignSprite.Observe

  @gateway_list_url "https://api.sprites.dev/v1/gateway/list"

  # Max silence between stream chunks before the call is declared
  # stalled. A live call streams thinking and text chunks steadily
  # (first chunk ~3s in the 2026-11-12 measurements); two minutes of
  # silence is a dead connection, not a slow model. App-env
  # overridable for tests.
  defp idle_timeout_ms do
    Application.get_env(:design_sprite, :ai_stream_idle_timeout_ms, 120_000)
  end

  # Bounded attempts per logical call (see the moduledoc): the
  # thinking-burn is stochastic per call, so a fresh attempt is a
  # genuinely new draw. Every attempt emits its own ai.call line.
  @max_call_attempts 4

  # Pause between attempts (attempt × unit): back-to-back draws
  # proved time-correlated live (three burns at ~83s each inside
  # four minutes), so retries space out to decorrelate. App-env
  # overridable for tests.
  defp retry_backoff_ms(attempt) do
    unit = Application.get_env(:design_sprite, :ai_retry_backoff_ms, 10_000)
    attempt * unit
  end

  @impl true
  def generate(system, user, schema) do
    case gateway_base_url() do
      {:ok, base_url} ->
        attempt_call(base_url, system, user, schema, 1)

      {:error, reason} ->
        # Discovery failures are call failures too — emit at this
        # layer as well (the first post-redeploy incident surfaced
        # only in ai.turn, with no ai.call line at all).
        Observe.emit(
          "ai.call",
          "failed",
          Map.put(DesignSprite.AI.ErrorInfo.fields(reason), "attempt", 0)
        )

        {:error, reason}
    end
  end

  defp attempt_call(base_url, system, user, schema, attempt) do
    opts = [
      api_key: "gateway-injected",
      base_url: base_url,
      system_prompt: system,
      max_tokens: 8192,
      receive_timeout: idle_timeout_ms(),
      stream_idle_timeout: idle_timeout_ms(),
      max_retries: 0,
      output_config: %{effort: "low"}
    ]

    started = System.monotonic_time(:millisecond)

    case stream_generate(model_spec(), user, schema, opts) do
      {:ok, object, chunks} ->
        Observe.emit("ai.call", "succeeded", %{
          duration_ms: System.monotonic_time(:millisecond) - started,
          chunks: chunks,
          attempt: attempt
        })

        {:ok, object}

      {:error, reason} ->
        # Provider metadata (status/type/message) is not user
        # content — emit it whole so the failure is diagnosable
        # from the log (F5); the 80-char inspect truncation hid a
        # billing failure behind "Provider response error (40".
        fields =
          DesignSprite.AI.ErrorInfo.fields(reason)
          |> Map.put("duration_ms", System.monotonic_time(:millisecond) - started)
          |> Map.put("attempt", attempt)

        Observe.emit("ai.call", "failed", fields)

        if attempt < @max_call_attempts do
          Process.sleep(retry_backoff_ms(attempt))
          attempt_call(base_url, system, user, schema, attempt + 1)
        else
          {:error, {:ai_call_failed, reason}}
        end
    end
  end

  # One streaming structured-output call, consumed to completion.
  # Returns {:ok, string_keyed_object, chunk_count} or {:error, _}.
  # Stream errors surface however the library raises them (returned
  # error tuple, raised exception, thrown exit) — all become one
  # {:error, _} for the driver; nothing here retries.
  defp stream_generate(model, user, schema, opts) do
    with {:ok, %ReqLLM.StreamResponse{} = response} <-
           ReqLLM.stream_object(model, user, schema, opts) do
      consume(response)
    end
  rescue
    e -> {:error, e}
  catch
    kind, term -> {:error, {kind, term}}
  end

  defp consume(response) do
    counter = :counters.new(1, [])
    tapped = Stream.each(response.stream, fn _chunk -> :counters.add(counter, 1, 1) end)

    case ReqLLM.StreamResponse.to_response(%{response | stream: tapped}) do
      {:ok, %ReqLLM.Response{} = resp} -> finish(resp, :counters.get(counter, 1))
      %ReqLLM.Response{} = resp -> finish(resp, :counters.get(counter, 1))
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_stream_result, other}}
    end
  rescue
    e -> {:error, e}
  catch
    kind, term -> {:error, {kind, term}}
  end

  # The reply object is the whole point of the call. A response with
  # no object — the thinking-burn signature (stop_reason max_tokens,
  # thinking blocks only, zero reply text) — is a failed call, never
  # a successful empty turn.
  defp finish(%ReqLLM.Response{} = resp, chunks) do
    case ReqLLM.Response.object(resp) do
      object when is_map(object) -> {:ok, string_keys(object), chunks}
      _no_object -> {:error, :empty_object_response}
    end
  end

  # The driver contract is string keys end to end; a JSON round trip
  # normalizes whatever key style the library returns.
  defp string_keys(object) when is_map(object) do
    object |> JSON.encode!() |> JSON.decode!()
  end

  defp string_keys(_other), do: %{}

  defp model_spec do
    model = Application.get_env(:design_sprite, :ai_model) || "claude-fable-5-2"
    if String.contains?(model, ":"), do: model, else: "anthropic:" <> model
  end

  @doc "Resolve the gateway base URL for the anthropic connection (cached after first success)."
  def gateway_base_url do
    case Application.get_env(:design_sprite, :ai_gateway_url) do
      url when is_binary(url) and url != "" ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        discover()
    end
  end

  # Discovery runs lazily inside the first turn of a process and its
  # success is cached for the process lifetime — so a single
  # transient control-plane failure here would kill a whole turn and
  # (as first shipped) misreport itself as "connection not found".
  # Observed live 2026-11-12: the first turn after a redeploy failed
  # at 78.7s with :anthropic_gateway_connection_not_found while the
  # same list call, retried moments later from the same sprite,
  # returned the anthropic connection in 0.5s. The list call is cheap
  # and idempotent: retry it, and report transport failure honestly —
  # "not found" is reserved for a list that actually lacks the
  # connection.
  @discovery_attempts 3

  defp discover(attempt \\ 1) do
    case fetch_gateway_list() do
      {:ok, conns} ->
        case Enum.find(conns, fn c -> c["provider"] == "anthropic" end) do
          %{"gateway_base_url" => base} ->
            base = String.trim_trailing(base, "/")
            Application.put_env(:design_sprite, :ai_gateway_url, base)
            {:ok, base}

          _no_anthropic ->
            retry_discovery(attempt, :anthropic_gateway_connection_not_found)
        end

      {:error, reason} ->
        retry_discovery(attempt, {:gateway_discovery_failed, reason})
    end
  end

  defp retry_discovery(attempt, failure) when attempt < @discovery_attempts do
    Process.sleep(attempt * 500)
    discover(attempt + 1)
  end

  defp retry_discovery(_attempt, failure), do: {:error, failure}

  defp fetch_gateway_list do
    url =
      Application.get_env(:design_sprite, :ai_gateway_list_url) || @gateway_list_url

    case Req.get(url,
           receive_timeout: 15_000,
           connect_options: [timeout: 10_000],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"connections" => conns}}} -> {:ok, conns}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
