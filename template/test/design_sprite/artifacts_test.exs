defmodule DesignSprite.ArtifactsTest do
  use ExUnit.Case, async: false

  alias DesignSprite.{Artifacts, ProjectFiles, Record, TestSupport}

  @v1 "<!doctype html><body><h1 id=\"hero\">Hello</h1><p>First</p></body>"

  # 12 meaningful elements, zero ids (the F4 pilot shape).
  @big_no_ids "<!doctype html><body><header><h1>Welcome</h1><nav><a href=\"/a\">A</a></nav></header><main><section><h2>About</h2><p>One.</p><p>Two.</p><button>Go</button></section></main><footer><p>Bye</p></footer></body>"

  # The same page with ids on 8 of its 12 meaningful elements.
  @big_with_ids "<!doctype html><body><header id=\"top\"><h1 id=\"hero\">Welcome</h1><nav id=\"nav\"><a href=\"/a\">A</a></nav></header><main id=\"main\"><section id=\"about\"><h2 id=\"about-h\">About</h2><p>One.</p><p>Two.</p><button id=\"go\">Go</button></section></main><footer id=\"foot\"><p>Bye</p></footer></body>"

  setup do
    TestSupport.wipe!()
    :ok
  end

  test "a snapshot enters as version 0 and the first edit becomes version 1" do
    assert {:ok, 0} = Artifacts.snapshot("legacy", @v1, "human")
    assert Artifacts.current_version("legacy") == 0
    assert Artifacts.current_html("legacy") == @v1
    assert ProjectFiles.read("artifacts/legacy.html", 0) == {:ok, @v1}
    assert Artifacts.version_numbers("legacy") == [0]

    assert {:ok, 1} = Artifacts.patch("legacy", "<h1 id=\"hero\">Hello</h1>", "<h1 id=\"hero\">Hi</h1>", "ai")
    assert Artifacts.current_html("legacy") =~ "Hi"
    # The snapshot bytes survive untouched in history.
    assert ProjectFiles.read("artifacts/legacy.html", 0) == {:ok, @v1}
  end

  test "a snapshot can only be version 0 of a new artifact" do
    assert {:ok, 0} = Artifacts.snapshot("legacy", @v1, "human")
    assert {:error, :artifact_exists} = Artifacts.snapshot("legacy", "<p>other</p>", "human")

    assert {:ok, 1} = Artifacts.write_new("fresh", @v1, "ai")
    assert {:error, :artifact_exists} = Artifacts.snapshot("fresh", "<p>other</p>", "human")
  end

  test "Record.snapshot_artifact lands the file and the stream entry together" do
    {:ok, _} = Record.create_project("Redesign the pricing page")

    assert {:ok, entry} = Record.snapshot_artifact("current-pricing", @v1, "human")
    assert entry.kind == "artifact"
    assert entry.payload["version"] == 0
    assert entry.payload["snapshot"] == true
    assert entry.payload["path"] == "artifacts/current-pricing.html"
    assert Artifacts.current_html("current-pricing") == @v1
  end

  test "a patch replaces exactly the targeted bytes; everything else survives" do
    assert {:ok, 1} = Artifacts.write_new("index", @v1, "ai")

    assert {:ok, 2} =
             Artifacts.patch("index", "<p>First</p>", "<p>Second</p>", "ai")

    html = Artifacts.current_html("index")
    assert html =~ "<p>Second</p>"
    assert html =~ "<h1 id=\"hero\">Hello</h1>"
    assert ProjectFiles.read("artifacts/index.html", 1) == {:ok, @v1}
    assert Artifacts.version_numbers("index") == [1, 2]
  end

  test "a patch whose target is missing or ambiguous writes nothing" do
    assert {:ok, 1} = Artifacts.write_new("index", @v1, "ai")

    assert {:error, :patch_target_not_found} =
             Artifacts.patch("index", "<p>Not there</p>", "<p>X</p>", "ai")

    assert {:error, :patch_target_not_unique} =
             Artifacts.patch("index", "o", "0", "ai")

    assert Artifacts.current_version("index") == 1
    assert Artifacts.current_html("index") == @v1
  end

  test "patching a missing artifact is a clean error" do
    assert {:error, :no_artifact} = Artifacts.patch("nope", "x", "y", "ai")
    assert {:error, :no_artifact} = Artifacts.patch_check("nope", "x")
    assert Artifacts.current_html("nope") == nil
  end

  test "patch_check validates without writing" do
    assert {:ok, 1} = Artifacts.write_new("index", @v1, "ai")
    assert :ok = Artifacts.patch_check("index", "<p>First</p>")
    assert {:error, :patch_target_not_found} = Artifacts.patch_check("index", "zzz")
    assert Artifacts.current_version("index") == 1
  end

  # ----------------------------------------------------------------
  # F4: element ids enforced at write time

  test "id_coverage counts meaningful elements and the identified ones" do
    assert Artifacts.id_coverage(@v1) == %{meaningful: 2, identified: 1}
    assert Artifacts.id_coverage(@big_no_ids) == %{meaningful: 12, identified: 0}
    assert Artifacts.id_coverage(@big_with_ids) == %{meaningful: 12, identified: 8}
    # Layout wrappers are not meaningful either way.
    assert Artifacts.id_coverage("<div><span>x</span></div>") == %{meaningful: 0, identified: 0}
  end

  test "a non-trivial artifact with no ids is refused at write time; one with ids lands" do
    assert {:error, :artifact_ids_missing} = Artifacts.write_new("index", @big_no_ids, "ai")
    assert Artifacts.current_html("index") == nil
    assert Artifacts.version_numbers("index") == []

    assert {:ok, 1} = Artifacts.write_new("index", @big_with_ids, "ai")
    assert Artifacts.current_html("index") == @big_with_ids
  end

  test "a trivial artifact needs no ids" do
    assert {:ok, 1} = Artifacts.write_new("index", "<p>just a note</p>", "ai")
  end

  test "a snapshot of an id-less page still enters as version 0 (snapshots are exempt)" do
    assert {:ok, 0} = Artifacts.snapshot("legacy", @big_no_ids, "human")
    assert Artifacts.current_html("legacy") == @big_no_ids
  end

  test "a patch introducing non-trivial id-less structure writes nothing" do
    assert {:ok, 1} = Artifacts.write_new("index", @v1, "ai")

    fragment = "<section><h2>New</h2><p>One.</p><p>Two.</p></section>"

    assert {:error, :artifact_ids_missing} =
             Artifacts.patch("index", "<p>First</p>", fragment, "ai")

    assert Artifacts.current_version("index") == 1
    assert Artifacts.current_html("index") == @v1

    with_ids = "<section id=\"s\"><h2 id=\"s-h\">New</h2><p>One.</p><p>Two.</p></section>"
    assert {:ok, 2} = Artifacts.patch("index", "<p>First</p>", with_ids, "ai")
    assert Artifacts.current_html("index") =~ "id=\"s\""
  end
end
