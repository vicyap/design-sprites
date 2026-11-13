defmodule DesignSprite.Export do
  @moduledoc """
  The exportable file set and the export bundle (contract item 7).

  ONE definition of the set, used by the web file explorer, the API,
  and the bundle itself — what you see is exactly what an
  implementing agent gets:

  - `transcript.md` — a live projection of the append-only record,
    regenerated on every read (the record is its own history);
  - `record.json` — the same record as structured data: project,
    entries verbatim, derived question views, tally, file index;
  - every versioned Project file (model.md, artifacts) at its path,
    with ALL versions kept — the bundle carries the latest at the
    natural path and every version under `history/<path>/v<n>`.

  The bundle is a zip built in memory: latest revision paramount at
  the top level, history underneath, nothing else.
  """

  alias DesignSprite.{ProjectFiles, Record}

  @transcript_path "transcript.md"
  @record_path "record.json"
  @projections [@transcript_path, @record_path]

  # ----------------------------------------------------------------
  # The exportable set

  @doc "Metadata for every exportable file, sorted by path."
  def exportable_files do
    projections =
      Enum.map(@projections, fn path ->
        {:ok, bytes} = read(path)

        %{
          path: path,
          kind: "projection",
          version: nil,
          versions: 0,
          bytes: byte_size(bytes),
          updated_at: last_activity_at()
        }
      end)

    files =
      Enum.map(ProjectFiles.list(), fn f ->
        Map.put(f, :kind, "file")
      end)

    Enum.sort_by(projections ++ files, & &1.path)
  end

  @doc "Read an exportable file: latest version, or a specific version number."
  def read(path, version \\ :latest)

  def read(@transcript_path, version) do
    if version in [:latest, nil] do
      {:ok, Record.transcript_text()}
    else
      {:error, :not_found}
    end
  end

  def read(@record_path, version) do
    if version in [:latest, nil] do
      {:ok, JSON.encode!(record_map())}
    else
      {:error, :not_found}
    end
  end

  def read(path, version) do
    ProjectFiles.read(path, version)
  end

  def projection?(path), do: path in @projections

  def content_type(path) do
    cond do
      String.ends_with?(path, ".md") -> "text/markdown"
      String.ends_with?(path, ".html") -> "text/html"
      String.ends_with?(path, ".json") -> "application/json"
      String.ends_with?(path, ".txt") -> "text/plain"
      true -> "application/octet-stream"
    end
  end

  # ----------------------------------------------------------------
  # The structured record (record.json + the API state shape)

  @doc "The whole Project as one structured map (string keys throughout)."
  def record_map do
    project = Record.project()

    %{
      "format" => "design-sprite-project",
      "version" => 1,
      "exported_at" => Record.now_iso(),
      "project" => project && project_map(project),
      "sharp" => Record.sharp?(),
      "tally" => tally_map(Record.tally()),
      "questions" => Enum.map(Record.question_views(), &question_map/1),
      "entries" => Enum.map(Record.entries(), &entry_map/1),
      # The lite index: record.json cannot carry its own byte size,
      # so inside the record its size is null; the explorer/API file
      # list (exportable_files/0) reports the true size.
      "files" => Enum.map(lite_files(), &file_map/1)
    }
  end

  defp lite_files do
    projections =
      Enum.map(@projections, fn path ->
        bytes =
          case path do
            @transcript_path -> byte_size(Record.transcript_text())
            _ -> nil
          end

        %{
          path: path,
          kind: "projection",
          version: nil,
          versions: 0,
          bytes: bytes,
          updated_at: last_activity_at()
        }
      end)

    files = Enum.map(ProjectFiles.list(), &Map.put(&1, :kind, "file"))
    Enum.sort_by(projections ++ files, & &1.path)
  end

  def project_map(project) do
    %{
      "id" => project.id,
      "want" => project.want,
      "title" => project.title,
      "status" => project.status,
      "committed_at" => project.committed_at,
      "created_at" => project.created_at
    }
  end

  def entry_map(entry) do
    %{
      "seq" => entry.seq,
      "kind" => entry.kind,
      "actor" => entry.actor,
      "body" => entry.body,
      "payload" => entry.payload || %{},
      "created_at" => entry.created_at
    }
  end

  def question_map(view) do
    %{
      "key" => view.key,
      "question" => view.question,
      "state" => to_string(view.state),
      "answer" => view.answer,
      "score" => view.score,
      "asked_seq" => view.asked_seq
    }
  end

  defp tally_map(tally) do
    Map.new(tally, fn {k, v} -> {to_string(k), v} end)
  end

  @doc "Public file-metadata map (the API/explorer shape)."
  def file_map_pub(f), do: file_map(f)

  defp file_map(f) do
    %{
      "path" => f.path,
      "kind" => f.kind,
      "version" => f.version,
      "versions" => f.versions,
      "bytes" => f.bytes,
      "updated_at" => f[:updated_at]
    }
  end

  # ----------------------------------------------------------------
  # The bundle

  @doc """
  Build the export bundle: {:ok, zip_binary, filename}. Contents:

  - every exportable file at its natural path, latest revision;
  - `history/<path>/v<n>` for every recorded version of every file;
  - nothing else — the bundle is the deliverable, not an archive of
    the sprite.
  """
  def bundle do
    if Record.project() == nil do
      {:error, :no_project}
    else
      files = bundle_entries()

      case :zip.create(~c"design-sprite-export.zip", files, [:memory]) do
        {:ok, {_name, zip}} -> {:ok, zip, bundle_filename()}
        {:error, _} = err -> err
      end
    end
  end

  defp bundle_entries do
    latest =
      Enum.map(exportable_files(), fn f ->
        {:ok, bytes} = read(f.path)
        {String.to_charlist(f.path), bytes}
      end)

    history =
      ProjectFiles.list()
      |> Enum.flat_map(fn f ->
        f.path
        |> ProjectFiles.versions()
        |> Enum.map(fn v ->
          {:ok, bytes} = ProjectFiles.read(f.path, v.version)
          {String.to_charlist("history/#{f.path}/v#{v.version}"), bytes}
        end)
      end)

    latest ++ history
  end

  defp bundle_filename do
    name =
      case Record.project() do
        %{title: title} when is_binary(title) and title != "" -> title
        %{want: want} when is_binary(want) -> want
        _ -> "project"
      end

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    "design-sprite-#{if slug == "", do: "project", else: slug}.zip"
  end

  defp last_activity_at do
    case List.last(Record.entries()) do
      %{created_at: at} -> at
      nil -> nil
    end
  end
end
