defmodule DesignSprite.Store do
  @moduledoc """
  SQLite schema bootstrap. Idempotent CREATE TABLE IF NOT EXISTS on boot,
  following the house pattern (v1 decision-sprite template): the deploy
  artifact never carries data; the SQLite file lives in the data dir.
  Ash resources map these tables 1:1. `DesignSprite.Release.migrate/0`
  runs this same DDL, so `run.sh`'s migrate step and app boot agree.

  Tables:
  - projects: the one Project this sprite hosts.
  - entries: THE append-only record. Everything that happens in a
    Project is one row here, forever. The domain exposes no update or
    destroy action for entries; corrections are new entries.
  - drafts: mutable half-answers (autosaved form state). Drafts are NOT
    part of the record; when a question is answered, the answer lands as
    an entry and the draft is deleted.
  - file_versions: one row per version of every versioned project file
    (model.md, artifacts). File bytes live on disk under data/files/;
    this table is the version index.
  - health_probes: backs the /health DB round trip.
  """

  alias DesignSprite.Repo

  def data_dir do
    Application.get_env(:design_sprite, :data_dir) ||
      System.get_env("DATA_DIR") || "/data"
  end

  def files_dir do
    Path.join(data_dir(), "files")
  end

  @tables [
    """
    CREATE TABLE IF NOT EXISTS projects (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      want TEXT NOT NULL,
      title TEXT,
      status TEXT NOT NULL DEFAULT 'open',
      committed_at TEXT,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      seq INTEGER NOT NULL,
      kind TEXT NOT NULL,
      actor TEXT NOT NULL,
      body TEXT,
      payload TEXT,
      created_at TEXT NOT NULL
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_entries_seq ON entries(seq)",
    "CREATE INDEX IF NOT EXISTS idx_entries_kind ON entries(kind)",
    """
    CREATE TABLE IF NOT EXISTS drafts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      question_key TEXT NOT NULL,
      payload TEXT,
      updated_at TEXT NOT NULL
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_drafts_question ON drafts(question_key)",
    """
    CREATE TABLE IF NOT EXISTS file_versions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT NOT NULL,
      version INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      bytes INTEGER NOT NULL,
      actor TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_file_versions_path_v ON file_versions(path, version)",
    """
    CREATE TABLE IF NOT EXISTS health_probes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      token TEXT NOT NULL
    )
    """
  ]

  def ensure_schema! do
    File.mkdir_p!(data_dir())
    File.mkdir_p!(files_dir())

    Enum.each(@tables, fn ddl ->
      Ecto.Adapters.SQL.query!(Repo, ddl)
    end)

    :ok
  end

  @doc "Real DB round trip for /health: write + read back a probe row."
  def health_probe! do
    token = :crypto.strong_rand_bytes(8) |> Base.encode16()

    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO health_probes (token) VALUES (?)", [token])

    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT COUNT(*) FROM health_probes WHERE token = ?", [
        token
      ])

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM health_probes WHERE token = ?", [token])
    count == 1
  end
end
