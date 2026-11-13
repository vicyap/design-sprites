defmodule DesignSprite.ProjectFilesTest do
  use ExUnit.Case, async: false

  alias DesignSprite.{ProjectFiles, TestSupport}

  setup do
    TestSupport.wipe!()
    :ok
  end

  test "versions accumulate; every version's bytes survive" do
    assert {:ok, 1} = ProjectFiles.write("model.md", "# Model v1", "ai")
    assert {:ok, 2} = ProjectFiles.write("model.md", "# Model v2", "ai")

    assert {:ok, "# Model v2"} = ProjectFiles.read("model.md")
    assert {:ok, "# Model v1"} = ProjectFiles.read("model.md", 1)
    assert {:ok, "# Model v2"} = ProjectFiles.read("model.md", 2)

    assert [%{path: "model.md", version: 2, versions: 2}] = ProjectFiles.list()
    assert ProjectFiles.model_text() == "# Model v2"
  end

  test "paths cannot escape the files dir" do
    assert {:error, :bad_path} = ProjectFiles.write("../evil.txt", "x", "ai")
    assert {:error, :bad_path} = ProjectFiles.write("/abs.txt", "x", "ai")
    assert {:error, :bad_path} = ProjectFiles.read("a/../../b")
    assert {:error, :bad_path} = ProjectFiles.write(".history/model.md", "x", "ai")
  end

  test "nested artifact paths work" do
    assert {:ok, 1} = ProjectFiles.write("artifacts/index.html", "<html>hi</html>", "ai")
    assert {:ok, "<html>hi</html>"} = ProjectFiles.read("artifacts/index.html")
  end

  test "reading a missing file is a clean error" do
    assert {:error, :not_found} = ProjectFiles.read("nope.md")
  end
end
