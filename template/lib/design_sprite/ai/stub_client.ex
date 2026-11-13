defmodule DesignSprite.AI.StubClient do
  @moduledoc """
  Test/dev AI adapter (Agent-backed). Tests queue canned turn replies
  — maps, or JSON strings (decoded here, so a non-JSON string surfaces
  the same :reply_not_json failure a broken transport would) — and can
  inspect the contexts the driver built.
  """

  @behaviour DesignSprite.AI.Client

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{replies: [], calls: []} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def set_replies(replies) when is_list(replies) do
    Agent.update(__MODULE__, &%{&1 | replies: replies})
  end

  def calls do
    Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{replies: [], calls: []} end)
  end

  @impl true
  def generate(system, user, schema) do
    reply =
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | calls: [%{system: system, user: user, schema: schema} | state.calls]}

        case state.replies do
          [reply | rest] -> {reply, %{state | replies: rest}}
          [] -> {:no_stub_reply, state}
        end
      end)

    deliver(reply)
  end

  # A queued {:sleep, ms, reply} simulates a hung/slow transport in
  # the caller (the driver task), never inside the Agent. A queued
  # {:error, term} passes the failure through untouched, so tests can
  # inject provider-shaped errors.
  defp deliver(:no_stub_reply), do: {:error, :no_stub_reply}

  defp deliver({:sleep, ms, reply}) do
    Process.sleep(ms)
    normalize(reply)
  end

  defp deliver({:error, _reason} = error), do: error

  defp deliver(reply), do: normalize(reply)

  defp normalize(reply) when is_map(reply), do: {:ok, reply}

  defp normalize(reply) when is_binary(reply) do
    case JSON.decode(reply) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :reply_not_json}
    end
  end
end
