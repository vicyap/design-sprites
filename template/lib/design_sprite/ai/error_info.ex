defmodule DesignSprite.AI.ErrorInfo do
  @moduledoc """
  Provider error metadata for Observe (pilot finding F5).

  When an AI call fails, the log must say WHY at a glance — billing,
  schema, rate limit, timeout — because the operator's response
  differs for each, and during the pilot the billing cause ("credit
  balance too low") was recoverable only by re-running a turn in an
  in-sprite eval: both Observe sites truncated `inspect(reason)` at
  80 chars, mid-word.

  Provider error text is NOT user content. Anthropic's error type,
  HTTP status and message describe the provider's own failure; they
  never quote the Project's want, answers or comments. `fields/1`
  extracts exactly those — a short label (our atom or the error's
  struct class), the provider status, its error type/code, and its
  message capped at #{300} chars — from whatever shape the failure
  arrived in: ReqLLM Splode errors (`%ReqLLM.Error.API.*` carry
  `status`, `reason` and the raw `response_body`), decoded Anthropic
  error bodies (`{"error": {"type", "message"}}`), transport errors,
  and our own atoms/tuples.

  Nothing here echoes request content, so the log's content greps
  stay at zero exactly as before.
  """

  @max_message 300

  @doc """
  Observe fields for a failure reason. Always carries "error" (the
  label); provider fields appear only when the reason carries them.
  """
  def fields(reason) do
    {label, target} = unwrap(reason)
    body = provider_body(target)

    [
      {"error", label},
      {"error_status", status_of(target)},
      {"error_type", body_type(body) || provider_code(target) || atom_reason(target)},
      {"error_message",
       cap(body_message(body) || string_field(target, :reason) || exception_message(target))}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  # Our own wrapper: {:ai_call_failed, inner} — the label names the
  # wrapper, the metadata comes from the provider error inside.
  defp unwrap({:ai_call_failed, inner}), do: {"ai_call_failed", inner}
  defp unwrap({:gateway_discovery_failed, inner}), do: {"gateway_discovery_failed", inner}
  defp unwrap(reason), do: {label(reason), reason}

  defp label(%mod{}), do: inspect(mod)
  defp label(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp label(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    tuple |> elem(0) |> label()
  end

  defp label(binary) when is_binary(binary), do: "string"
  defp label(_other), do: "unknown"

  # Splode error classes aggregate their leaf errors under :errors;
  # the metadata lives on the leaf.
  defp leaf(%{errors: [first | _]}), do: leaf(first)
  defp leaf(other), do: other

  defp field(target, key) do
    case leaf(target) do
      %{} = map -> Map.get(map, key) || Map.get(map, to_string(key))
      _ -> nil
    end
  end

  defp string_field(target, key) do
    case field(target, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp status_of(target) do
    case field(target, :status) || field(target, :status_code) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp provider_code(target), do: string_field(target, :provider_code)

  # Transport-style errors carry their reason as an atom (:timeout,
  # :econnrefused…) — that atom IS the diagnosis, so it surfaces as
  # the error type.
  defp atom_reason(target) do
    case field(target, :reason) do
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  # The provider's own error body: a ReqLLM leaf's response_body (raw
  # JSON string or already decoded), a nested :body, or the reason
  # itself when it already is the decoded Anthropic shape.
  defp provider_body(target) do
    raw = field(target, :response_body) || field(target, :body)

    cond do
      is_map(raw) -> raw
      is_binary(raw) -> decode(raw)
      is_map(leaf(target)) and is_map(field(target, :error)) -> leaf(target)
      true -> nil
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end

  defp body_type(body) when is_map(body) do
    inner = if is_map(body["error"]), do: body["error"], else: %{}
    inner["type"] || inner["code"] || body["code"]
  end

  defp body_type(_body), do: nil

  defp body_message(body) when is_map(body) do
    inner = if is_map(body["error"]), do: body["error"], else: %{}
    inner["message"] || body["message"]
  end

  defp body_message(_body), do: nil

  # Last resort: the error's own message (ReqLLM builds these from
  # the provider response; they are provider-facing text, e.g.
  # "Provider response error (400): …").
  defp exception_message(%mod{} = struct) do
    if function_exported?(mod, :message, 1) do
      try do
        case Exception.message(struct) do
          text when is_binary(text) -> text
          _ -> nil
        end
      rescue
        _ -> nil
      end
    end
  end

  defp exception_message(_other), do: nil

  defp cap(nil), do: nil
  defp cap(text) when is_binary(text), do: String.slice(text, 0, @max_message)
end
