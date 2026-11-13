defmodule DesignSprite.ApiParityTest do
  @moduledoc """
  Phase 4 parity at the Api layer: external drivers get the web UI's
  capabilities over the same actions, under the same one-Driver rule
  (lease instead of Presence), including the full Commit arc.
  """
  use ExUnit.Case, async: false

  alias DesignSprite.{Api, Record, TestSupport}
  alias DesignSprite.AI.StubClient

  @me "agent-muse"
  @other "agent-codex"

  setup do
    TestSupport.wipe!()
    :ok
  end

  test "mutations without the lease are refused; a second driver is refused" do
    assert {:error, :driver_required} = Api.post_message(@me, %{"text" => "hello", "actor" => "agent"})
    assert {:error, :driver_id_required} = Api.post_message(nil, %{"text" => "hello"})
    assert {:error, :driver_id_required} = Api.acquire_driver("")

    assert {:ok, _} = Api.acquire_driver(@me)
    assert {:error, :driver_held} = Api.acquire_driver(@other)
    assert {:error, :driver_held} = Api.post_message(@other, %{"text" => "hello", "actor" => "agent"})

    # The holder can act; mutating refreshes the lease.
    assert {:ok, _} = Api.post_message(@me, %{"text" => "holding the wheel", "actor" => "agent"})
    assert {:ok, %{"driver" => @me}} = Api.driver()

    assert {:error, :driver_not_held} = Api.release_driver(@other)
    assert {:ok, _} = Api.release_driver(@me)
    assert {:ok, %{"driver" => nil}} = Api.driver()
    assert {:ok, _} = Api.acquire_driver(@other)
    Api.release_driver(@other)
  end

  test "a full Project arc driven purely through the Api" do
    assert {:ok, _} = Api.acquire_driver(@me)

    # Create + question + answer.
    assert {:ok, %{"project" => %{"status" => "open"}}} =
             Api.create_project(@me, "Design a settings page")

    assert {:ok, _} = Api.post_question(@me, TestSupport.question("layout"))

    assert {:ok, %{"answer" => answer, "score" => score}} =
             Api.answer_question(@me, "layout", %{"choice" => "alpha", "actor" => "agent"})

    assert answer["payload"]["choice"] == "alpha"
    assert score["payload"]["result"] == "hit"

    # Artifact write + patch + snapshot parity.
    assert {:ok, %{"version" => 1}} =
             Api.write_artifact(@me, "index", "<html><body><p id=\"note\">long note here</p></body></html>")

    assert {:ok, %{"version" => 2}} =
             Api.patch_artifact(@me, "index", %{
               "find" => "long note here",
               "replace" => "short",
               "element" => "body > p"
             })

    assert DesignSprite.Artifacts.current_html("index") =~ "short"

    assert {:error, :patch_target_not_found} =
             Api.patch_artifact(@me, "index", %{"find" => "not there", "replace" => "x"})

    assert {:ok, %{"version" => 0}} =
             Api.snapshot_artifact(@me, "legacy", "<html><body>legacy</body></html>")

    # Model write parity.
    assert {:ok, %{"version" => 1}} = Api.write_model(@me, "# Model\n- Layout: alpha.")
    assert DesignSprite.ProjectFiles.model_text() =~ "Layout: alpha"

    # Sharpness gate refuses a premature declaration, exactly as for
    # the built-in AI (only one answered question so far).
    assert {:error, :sharpness_gate} = Api.declare_sharp(@me)

    # State read-back reflects everything, no lease needed for reads.
    assert {:ok, state} = Api.state()
    assert state["tally"]["answered"] == 1
    assert state["driver"] == @me
    assert Enum.any?(state["files"], &(&1["path"] == "artifacts/index.html"))

    # Commit through the Api, then the lock semantics bite.
    assert {:ok, %{"project" => %{"status" => "committed"}}} = Api.commit(@me)
    assert {:error, :committed} = Api.post_message(@me, %{"text" => "too late", "actor" => "agent"})
    assert {:error, :committed} = Api.write_artifact(@me, "index", "<html>v3</html>")
    assert {:error, :already_committed} = Api.commit(@me)

    # …but Decided-for-you still appends, and reads still work.
    assert {:ok, %{"entry" => entry}} =
             Api.append_decision(@me, "Implemented the settings page from model v1.")

    assert entry["kind"] == "decision"
    assert {:ok, state} = Api.state()
    assert state["project"]["status"] == "committed"
    assert {:ok, %{"bytes" => transcript}} = Api.read_file("transcript.md")
    assert transcript =~ "Implemented the settings page"

    assert {:ok, _} = Api.release_driver(@me)
  end

  test "re-answering through the Api supersedes; after Commit it is refused" do
    assert {:ok, _} = Api.acquire_driver(@me)
    assert {:ok, _} = Api.create_project(@me, "Design a settings page")
    assert {:ok, _} = Api.post_question(@me, TestSupport.question("layout"))

    assert {:ok, %{"score" => s1}} =
             Api.answer_question(@me, "layout", %{"choice" => "alpha", "actor" => "agent"})

    assert s1["payload"]["result"] == "hit"

    assert {:ok, %{"answer" => a2, "score" => s2}} =
             Api.answer_question(@me, "layout", %{"choice" => "beta", "actor" => "agent"})

    assert a2["payload"]["superseding"] == true
    assert s2["payload"]["result"] == "miss"

    # State reflects ONLY the latest; both answers remain in history.
    assert {:ok, state} = Api.state()
    assert state["tally"] == %{"answered" => 1, "hits" => 0, "misses" => 1, "open" => 0, "skipped" => 0, "struck" => 0}
    answers = Enum.filter(state["entries"], &(&1["kind"] == "answer"))
    assert Enum.map(answers, & &1["payload"]["choice"]) == ["alpha", "beta"]

    assert {:ok, _} = Api.commit(@me)
    assert {:error, :committed} = Api.answer_question(@me, "layout", %{"choice" => "alpha", "actor" => "agent"})

    assert {:ok, _} = Api.release_driver(@me)
  end

  test "skip and strike through the Api follow the record rules" do
    assert {:ok, _} = Api.acquire_driver(@me)
    assert {:ok, _} = Api.create_project(@me, "Design a settings page")
    assert {:ok, _} = Api.post_question(@me, TestSupport.question("layout"))
    assert {:ok, _} = Api.post_question(@me, TestSupport.question("tone"))

    assert {:ok, _} = Api.skip_question(@me, "layout", %{"note" => "skip for now"})
    assert Record.question_view("layout").state == :skipped

    assert {:ok, _} = Api.strike_question(@me, "tone", %{"note" => "out of scope"})
    assert Record.question_view("tone").state == :struck
    assert {:error, :question_struck} = Api.answer_question(@me, "tone", %{"choice" => "alpha"})
    assert {:error, :question_not_found} = Api.answer_question(@me, "nope", %{"choice" => "alpha"})

    Api.release_driver(@me)
  end

  test "a human-actor message through the Api kicks the built-in driver, like the web" do
    StubClient.set_replies([
      Jason.encode!(%{
        "messages" => ["On it."],
        "actions" => [],
        "score_judgements" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "artifact_patch" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, _} = Api.acquire_driver(@me)
    assert {:ok, _} = Api.create_project(@me, "Design a settings page")

    # create_project itself kicks once (the web's Begin does too);
    # drain that turn before asserting on the message-driven one.
    assert TestSupport.eventually(fn ->
             Enum.any?(Record.entries(), &(&1.kind == "message" and &1.actor == "ai"))
           end)

    entries_before = length(Record.entries())

    StubClient.set_replies([
      Jason.encode!(%{
        "messages" => ["Noted — one screen it is."],
        "actions" => [],
        "score_judgements" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "artifact_patch" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, _} = Api.post_message(@me, %{"text" => "Keep it to one screen.", "actor" => "human"})

    assert TestSupport.eventually(fn ->
             Enum.any?(Record.entries(), fn e ->
               e.kind == "message" and e.body == "Noted — one screen it is."
             end)
           end)

    assert length(Record.entries()) > entries_before
    Api.release_driver(@me)
  end
end
