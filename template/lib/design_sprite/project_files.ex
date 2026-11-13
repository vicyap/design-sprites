defmodule DesignSprite.ProjectFiles do
  @moduledoc """
  Project files on disk (contract item 7). Versioned writes:

  - data/files/<path>                — the current version's bytes
  - data/files/.history/<path>/v<n>  — every version's bytes, forever
  - file_versions rows               — the version index (sha, actor)

  The file explorer and the export bundle serve exactly this set.
  transcript.md is the exception: a live projection of the record,
  regenerated on read, not versioned (the record is its history).

  Paths are confined to the files dir: no absolute paths, no `..`.
  """

  require Ash.Query

  alias DesignSprite.Resources.FileVersion
  alias DesignSprite.Store

  @history ".history"

  def root, do: Store.files_dir()

  @doc """
  Write a new version of a project file. Returns {:ok, version}.
  The Commit freeze applies here, at the storage layer, so NO surface
  (web, API, the AI driver) can write design content into a committed
  Project: {:error, :committed}.
  """
  def write(path, content, actor)
      when is_binary(content) and actor in ["human", "ai", "agent", "system"] do
    if DesignSprite.Record.committed?() do
      {:error, :committed}
    else
      with {:ok, rel} <- safe_rel(path) do
        write_version(rel, content, actor, next_version(rel))
      end
    end
  end

  @doc """
  Write a file at an EXPLICIT version (used for artifact snapshots,
  which enter as version 0). Fails with {:error, :version_exists} if
  that version is already recorded — history is never overwritten.
  """
  def write_at(path, content, actor, version)
      when is_binary(content) and is_integer(version) and version >= 0 and
             actor in ["human", "ai", "agent", "system"] do
    if DesignSprite.Record.committed?() do
      {:error, :committed}
    else
      with {:ok, rel} <- safe_rel(path) do
        if Enum.any?(versions(rel), &(&1.version == version)) do
          {:error, :version_exists}
        else
          write_version(rel, content, actor, version)
        end
      end
    end
  end

  defp write_version(rel, content, actor, version) do
    current = Path.join(root(), rel)
    history = Path.join([root(), @history, rel, "v#{version}"])

    File.mkdir_p!(Path.dirname(current))
    File.mkdir_p!(Path.dirname(history))
    File.write!(current, content)
    File.write!(history, content)

    {:ok, _} =
      FileVersion
      |> Ash.Changeset.for_create(:create, %{
        path: rel,
        version: version,
        sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
        bytes: byte_size(content),
        actor: actor,
        created_at: DesignSprite.Record.now_iso()
      })
      |> Ash.create()

    DesignSprite.Observe.emit("file.write", "succeeded", %{version: version})
    {:ok, version}
  end

  @doc "Read a file's bytes: latest version, or a specific version number."
  def read(path, version \\ :latest) do
    with {:ok, rel} <- safe_rel(path) do
      file =
        case version do
          :latest -> Path.join(root(), rel)
          n when is_integer(n) -> Path.join([root(), @history, rel, "v#{n}"])
        end

      case File.read(file) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, _} -> {:error, :not_found}
      end
    end
  end

  @doc "Latest-version metadata for every versioned file."
  def list do
    FileVersion
    |> Ash.read!()
    |> Enum.sort_by(& &1.version)
    |> Enum.group_by(& &1.path)
    |> Enum.map(fn {path, versions} ->
      latest = List.last(versions)

      %{
        path: path,
        version: latest.version,
        versions: length(versions),
        bytes: latest.bytes,
        sha256: latest.sha256,
        actor: latest.actor,
        updated_at: latest.created_at
      }
    end)
    |> Enum.sort_by(& &1.path)
  end

  @doc "All recorded versions of one path, newest first."
  def versions(path) do
    case safe_rel(path) do
      {:ok, rel} ->
        FileVersion
        |> Ash.Query.filter(path == ^rel)
        |> Ash.read!()
        |> Enum.sort_by(& &1.version, :desc)

      _ ->
        []
    end
  end

  def model_path, do: "model.md"

  @doc "The current model text (the model IS a file), or nil."
  def model_text do
    case read(model_path()) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  defp next_version(rel) do
    FileVersion
    |> Ash.Query.filter(path == ^rel)
    |> Ash.read!()
    |> Enum.map(& &1.version)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp safe_rel(path) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" -> {:error, :bad_path}
      String.starts_with?(path, "/") -> {:error, :bad_path}
      String.contains?(path, "\\") -> {:error, :bad_path}
      Path.split(path) |> Enum.any?(&(&1 in ["..", ".", @history])) -> {:error, :bad_path}
      true -> {:ok, path}
    end
  end

  defp safe_rel(_), do: {:error, :bad_path}
end
