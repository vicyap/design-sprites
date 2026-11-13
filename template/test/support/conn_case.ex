defmodule DesignSpriteWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import DesignSpriteWeb.ConnCase

      @endpoint DesignSpriteWeb.Endpoint
    end
  end

  setup _tags do
    DesignSprite.TestSupport.wipe!()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end

defmodule DesignSprite.TestSupport do
  @moduledoc """
  Reset all state between tests (no sandbox: the AshSqlite test DB is
  a scratch file; the record writer's in-memory seq simply keeps
  growing, which is harmless — uniqueness is what matters).
  """

  alias DesignSprite.Repo

  def wipe! do
    for table <- ["entries", "drafts", "file_versions", "projects", "health_probes"] do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table}")
    end

    files = DesignSprite.Store.files_dir()
    File.rm_rf!(files)
    File.mkdir_p!(files)

    if Process.whereis(DesignSprite.AI.StubClient) do
      DesignSprite.AI.StubClient.reset()
    end

    if holder = DesignSprite.DriverLock.holder() do
      DesignSprite.DriverLock.release(holder)
    end

    :ok
  end

  @doc "Poll `fun` until it returns truthy or the timeout (ms) expires."
  def eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(25)
        do_eventually(fun, deadline)
    end
  end

  def token, do: DesignSprite.Token.current()

  def authed(conn) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token())
  end

  @doc "A valid question payload for tests."
  def question(key, overrides \\ %{}) do
    Map.merge(
      %{
        "key" => key,
        "axis" => key,
        "type" => "single",
        "prompt" => "Question #{key}?",
        "context" => nil,
        "options" => [
          %{"value" => "alpha", "label" => "Alpha"},
          %{"value" => "beta", "label" => "Beta"}
        ],
        "prediction" => "alpha",
        "recommended" => nil
      },
      overrides
    )
  end
end
