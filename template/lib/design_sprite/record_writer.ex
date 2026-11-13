defmodule DesignSprite.RecordWriter do
  @moduledoc """
  The single writer for the append-only record. Every entry append in
  the system funnels through this GenServer, which assigns the
  monotonic `seq` — so two surfaces (web, API, the AI driver) can
  never race or interleave the record. Reads never come here; see
  DesignSprite.Record.

  Append-only is structural: entries have no update/destroy actions,
  and this process only ever inserts.
  """

  use GenServer

  alias DesignSprite.Resources.Entry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Append one entry. Returns {:ok, entry} or {:error, reason}.
  `attrs`: %{kind, actor, body, payload} — seq and created_at are
  assigned here.
  """
  def append(attrs) do
    GenServer.call(__MODULE__, {:append, attrs}, 30_000)
  end

  @impl true
  def init(_opts) do
    # seq is loaded lazily on first append: at supervisor boot the
    # schema may not exist yet (Application ensures it right after
    # the tree starts; calls queue behind init regardless).
    {:ok, %{seq: nil}}
  end

  @impl true
  def handle_call({:append, attrs}, _from, state) do
    seq = (state.seq || current_max_seq()) + 1

    params = %{
      seq: seq,
      kind: attrs.kind,
      actor: attrs.actor,
      body: attrs[:body],
      payload: attrs[:payload],
      created_at: DesignSprite.Record.now_iso()
    }

    case Entry |> Ash.Changeset.for_create(:create, params) |> Ash.create() do
      {:ok, entry} ->
        Phoenix.PubSub.broadcast(
          DesignSprite.PubSub,
          "project",
          {:entry_appended, entry}
        )

        {:reply, {:ok, entry}, %{state | seq: seq}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp current_max_seq do
    Entry
    |> Ash.read!()
    |> Enum.map(& &1.seq)
    |> Enum.max(fn -> 0 end)
  end
end
