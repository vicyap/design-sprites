defmodule DesignSprite.LogScrubTest do
  @moduledoc """
  Phase 4 rider: OTP crash reports embed a crashed process's last
  message — for a LiveView that can be a form event carrying answer
  content verbatim (the Phase 3 probe incident). The scrub
  translator must render crash reports without any of that content
  while keeping the crash itself visible.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DesignSprite.LogScrub

  defmodule Crashy do
    use GenServer

    def start, do: GenServer.start(__MODULE__, nil)
    def init(_), do: {:ok, %{}}

    def handle_call({:explode, _secret}, _from, _state) do
      raise "boom"
    end
  end

  test "the translator scrubs gen_server terminate reports to label + name + reason class" do
    report = %{
      label: {:gen_server, :terminate},
      name: self(),
      last_message_in_queue: {:explode, "SECRET-ANSWER-TEXT"},
      state: %{draft: "SECRET-ANSWER-TEXT"},
      reason: {%RuntimeError{message: "SECRET-ANSWER-TEXT"}, []},
      queue: [],
      log: []
    }

    assert {:ok, text} = LogScrub.translate(:error, :error, :report, {:report, report})
    assert text =~ "crash report scrubbed"
    assert text =~ "gen_server"
    assert text =~ "RuntimeError"
    refute text =~ "SECRET-ANSWER-TEXT"
  end

  test "non-crash reports fall through to the default translator" do
    report = %{label: {:supervisor, :progress}, pid: self()}
    assert LogScrub.translate(:info, :info, :report, {:report, report}) == :none
    assert LogScrub.translate(:info, :info, :format, {"hello", []}) == :none
  end

  test "a real GenServer crash logs the scrub line and never the message content" do
    {:ok, pid} = Crashy.start()
    ref = Process.monitor(pid)

    log =
      capture_log([level: :error], fn ->
        catch_exit(GenServer.call(pid, {:explode, "SECRET-ANSWER-TEXT"}))
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
        # Logger is async; give the report a moment to flush.
        Process.sleep(150)
      end)

    assert log =~ "crash report scrubbed"
    refute log =~ "SECRET-ANSWER-TEXT"
  end
end
