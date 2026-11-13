defmodule DesignSprite.DriverLock do
  @moduledoc """
  The one-Driver rule (contract item 1). Exactly one holder at a time.

  - Web holders pass their LiveView pid: the lock monitors it, so the
    lock dies with the Driver's presence — a dead tab frees the seat
    and the next visitor can drive (half-answers persist as drafts).
  - API holders pass pid=nil and heartbeat instead: an idle lease
    older than the TTL is swept. (TTL is the API-side equivalent of
    presence — see STATUS.md decision D2.)
  """

  use GenServer

  @ttl_ms 10 * 60 * 1000
  @sweep_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Acquire the Driver seat for `id`. pid: the web LiveView pid, or nil (API lease)."
  def acquire(id, pid \\ nil) when is_binary(id) do
    GenServer.call(__MODULE__, {:acquire, id, pid})
  end

  def release(id), do: GenServer.call(__MODULE__, {:release, id})
  def heartbeat(id), do: GenServer.call(__MODULE__, {:heartbeat, id})

  @doc "Current holder id, or nil."
  def holder, do: GenServer.call(__MODULE__, :holder)

  def held_by?(id), do: holder() == id

  # ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{holder: nil}}
  end

  @impl true
  def handle_call({:acquire, id, pid}, _from, state) do
    case state.holder do
      nil ->
        {:reply, :ok, put_holder(state, id, pid)}

      %{id: ^id} ->
        {:reply, :ok, put_holder(state, id, pid)}

      %{id: other} ->
        {:reply, {:error, :held, other}, state}
    end
  end

  def handle_call({:release, id}, _from, state) do
    case state.holder do
      %{id: ^id} -> {:reply, :ok, %{state | holder: nil}}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:heartbeat, id}, _from, state) do
    case state.holder do
      %{id: ^id} = holder ->
        {:reply, :ok, %{state | holder: %{holder | last_seen: now_ms()}}}

      _ ->
        {:reply, {:error, :not_held}, state}
    end
  end

  def handle_call(:holder, _from, state) do
    {:reply, state.holder && state.holder.id, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case state.holder do
      %{monitor: ^ref} ->
        Phoenix.PubSub.broadcast(DesignSprite.PubSub, "project", :driver_released)
        {:noreply, %{state | holder: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    schedule_sweep()

    case state.holder do
      %{pid: nil, last_seen: seen} when is_integer(seen) ->
        if now_ms() - seen > @ttl_ms do
          Phoenix.PubSub.broadcast(DesignSprite.PubSub, "project", :driver_released)
          {:noreply, %{state | holder: nil}}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp put_holder(state, id, pid) do
    monitor = if is_pid(pid), do: Process.monitor(pid), else: nil
    %{state | holder: %{id: id, pid: pid, monitor: monitor, last_seen: now_ms()}}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
