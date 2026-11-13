defmodule DesignSprite.ExportTest do
  use ExUnit.Case, async: false

  alias DesignSprite.{Artifacts, Export, ProjectFiles, Record, TestSupport}

  setup do
    TestSupport.wipe!()
    {:ok, _} = Record.create_project("Design a settings page for a coffee shop app")
    {:ok, 1} = ProjectFiles.write("model.md", "# Model v1\n- Layout: alpha.", "ai")
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))
    {:ok, _} = Record.answer_question("layout", %{"choice" => "alpha"}, "human")
    {:ok, 0} = Artifacts.snapshot("index", "<html><body><h1>Old</h1></body></html>", "human")
    {:ok, 1} = Artifacts.write_new("index", "<html><body><h1>New</h1></body></html>", "ai")
    {:ok, 2} = ProjectFiles.write("model.md", "# Model v2\n- Layout: alpha, settled.", "ai")
    :ok
  end

  test "the exportable set is exactly: projections + every versioned file" do
    files = Export.exportable_files()
    paths = Enum.map(files, & &1.path)

    assert paths == ["artifacts/index.html", "model.md", "record.json", "transcript.md"]

    model = Enum.find(files, &(&1.path == "model.md"))
    assert model.kind == "file"
    assert model.version == 2
    assert model.versions == 2

    artifact = Enum.find(files, &(&1.path == "artifacts/index.html"))
    assert artifact.version == 1
    assert artifact.versions == 2

    transcript = Enum.find(files, &(&1.path == "transcript.md"))
    assert transcript.kind == "projection"
    assert transcript.bytes > 0
  end

  test "projections read live: transcript verbatim, record.json structured" do
    assert {:ok, transcript} = Export.read("transcript.md")
    assert transcript =~ "Design a settings page"
    assert transcript =~ "score(layout): hit"

    assert {:ok, json} = Export.read("record.json")
    record = JSON.decode!(json)
    assert record["format"] == "design-sprite-project"
    assert record["project"]["want"] =~ "settings page"
    assert record["tally"]["hits"] == 1
    assert [%{"key" => "layout", "state" => "answered"}] = record["questions"]
    # Inside record.json the file index cannot carry record.json's own
    # size — every other file's metadata is present.
    record_file = Enum.find(record["files"], &(&1["path"] == "record.json"))
    assert record_file["bytes"] == nil
    model_file = Enum.find(record["files"], &(&1["path"] == "model.md"))
    assert model_file["versions"] == 2
  end

  test "versioned reads: latest paramount, history exact" do
    assert {:ok, "# Model v2" <> _} = Export.read("model.md")
    assert {:ok, "# Model v1" <> _} = Export.read("model.md", 1)
    assert {:ok, html_v0} = Export.read("artifacts/index.html", 0)
    assert html_v0 =~ "Old"
    assert {:error, :not_found} = Export.read("model.md", 99)
    assert {:error, :not_found} = Export.read("transcript.md", 3)
  end

  test "the bundle: latest at natural paths, every version under history/" do
    assert {:ok, zip, filename} = Export.bundle()
    assert filename =~ ".zip"

    {:ok, files} = :zip.unzip(zip, [:memory])
    by_name = Map.new(files, fn {name, bytes} -> {to_string(name), bytes} end)

    assert by_name["model.md"] =~ "Model v2"
    assert by_name["history/model.md/v1"] =~ "Model v1"
    assert by_name["history/model.md/v2"] =~ "Model v2"
    assert by_name["artifacts/index.html"] =~ "New"
    assert by_name["history/artifacts/index.html/v0"] =~ "Old"
    assert by_name["history/artifacts/index.html/v1"] =~ "New"
    assert by_name["transcript.md"] =~ "score(layout): hit"

    record = JSON.decode!(by_name["record.json"])
    assert record["project"]["status"] == "open"

    # Nothing else sneaks in: no DB, no token, no sprite internals.
    refute Map.has_key?(by_name, "app.db")
    assert Enum.all?(Map.keys(by_name), &(&1 in ["model.md", "transcript.md", "record.json", "artifacts/index.html"] or String.starts_with?(&1, "history/")))
  end

  test "no project, no bundle" do
    TestSupport.wipe!()
    assert {:error, :no_project} = Export.bundle()
  end
end
