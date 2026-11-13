defmodule DesignSprite.LogScrub do
  @moduledoc """
  Keeps entry CONTENT out of crash reports in the log.

  OTP crash reports (a GenServer terminating, a proc_lib crash, a
  supervisor reporting a dead child) embed the process's last
  message and state — for a LiveView, that message can be a form
  event carrying a Driver's answer text verbatim (observed live in
  Phase 3: a malformed probe event quoted the message payload into
  the service log). Observe emissions are counts/ids-only by design;
  this closes the same hole on the crash path.

  Two layers, because which component formats a report depends on
  the Logger setup (on this stack the Erlang default handler renders
  reports before Elixir's translator chain sees them):

  1. A :logger PRIMARY FILTER, installed at boot (Application):
     it rewrites a crash report event's message to a one-line
     scrubbed string — label + process + reason CLASS, never a
     value — before ANY handler or formatter can see the content.
  2. A Logger translator (config :logger, translators:) rendering
     the same scrubbed line on any path that does translate.

  Crashes stay VISIBLE (contract item 11) — just content-free.
  """

  @crash_labels [
    {:gen_server, :terminate},
    {:gen_event, :terminate},
    {:proc_lib, :crash},
    {:supervisor, :child_terminated},
    {:supervisor, :shutdown_error}
  ]

  # ----------------------------------------------------------------
  # Layer 1: the primary filter (:logger filter fun)

  @doc "Install the primary filter. Idempotent; safe to call at every boot."
  def install do
    :logger.remove_primary_filter(:ds_log_scrub)
    :logger.add_primary_filter(:ds_log_scrub, {&__MODULE__.filter/2, []})
    :ok
  end

  @doc false
  def filter(%{msg: {:report, report}} = event, _args) when is_map(report) do
    if report[:label] in @crash_labels do
      %{event | msg: {:string, scrubbed(report)}}
    else
      event
    end
  end

  def filter(event, _args), do: event

  # ----------------------------------------------------------------
  # Layer 2: the Logger translator

  def translate(_min_level, _level, :report, {:report, report}) when is_map(report) do
    if report[:label] in @crash_labels do
      {:ok, scrubbed(report)}
    else
      :none
    end
  end

  def translate(_min_level, _level, _kind, _data), do: :none

  # ----------------------------------------------------------------

  @doc "The scrubbed one-line rendering of a crash report (label + name + reason class only)."
  def scrubbed(report) do
    label = inspect(report[:label])
    name = inspect(report[:name] || report[:pid] || nested(report, :pid) || "unknown")
    reason = reason_class(report[:reason] || nested_reason(report))

    "crash report scrubbed (content withheld): label=#{label} name=#{name} reason_class=#{reason}\n"
  end

  # proc_lib / supervisor reports nest their detail under :report.
  defp nested(%{report: report}, key) when is_list(report) do
    report
    |> List.flatten()
    |> Enum.find_value(fn
      {^key, value} -> value
      _ -> nil
    end)
  end

  defp nested(_report, _key), do: nil

  defp nested_reason(%{report: report}) when is_list(report) do
    report
    |> List.flatten()
    |> Enum.find_value(fn
      {:error_info, {_kind, reason, _stack}} -> reason
      {:reason, reason} -> reason
      _ -> nil
    end)
  end

  defp nested_reason(_report), do: nil

  defp reason_class(%struct{}), do: inspect(struct)
  defp reason_class({%struct{}, _stack}), do: inspect(struct)
  defp reason_class({tag, _rest}) when is_atom(tag), do: inspect(tag)
  defp reason_class(reason) when is_atom(reason), do: inspect(reason)
  defp reason_class(_other), do: "unknown"
end
