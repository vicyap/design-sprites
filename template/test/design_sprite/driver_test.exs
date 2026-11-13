defmodule DesignSprite.DriverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias DesignSprite.{ProjectFiles, Record, TestSupport}
  alias DesignSprite.AI.{Driver, StubClient}

  # 13 meaningful elements (header/h1/nav/2 links/main/section/h2/2
  # paragraphs/button/footer/paragraph), zero ids — the F4 shape.
  @big_no_ids """
  <!doctype html><html><body>
  <header><h1>Welcome</h1><nav><a href="/a">A</a><a href="/b">B</a></nav></header>
  <main><section><h2>About</h2><p>Text one.</p><p>Text two.</p><button>Go</button></section></main>
  <footer><p>Bye</p></footer>
  </body></html>
  """

  @big_with_ids """
  <!doctype html><html><body>
  <header id="top"><h1 id="hero">Welcome</h1><nav id="nav"><a href="/a">A</a><a href="/b">B</a></nav></header>
  <main id="main"><section id="about"><h2 id="about-h">About</h2><p>Text one.</p><p>Text two.</p><button id="go">Go</button></section></main>
  <footer id="foot"><p>Bye</p></footer>
  </body></html>
  """

  defp reply(map), do: Jason.encode!(map)

  defp question_json(key) do
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
    }
  end

  setup do
    TestSupport.wipe!()
    {:ok, _} = Record.create_project("Design a settings page")
    :ok
  end

  test "a turn appends the AI's messages, questions and model" do
    StubClient.set_replies([
      reply(%{
        "messages" => ["Let's start with the shape of it."],
        "questions" => [question_json("layout")],
        "model" => "# Model v1\n- Layout: probably alpha.",
        "artifact" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert length(applied.questions) == 1

    assert Enum.any?(Record.entries(), &(&1.kind == "message" and &1.actor == "ai"))
    assert Record.question_view("layout").state == :open
    assert ProjectFiles.model_text() =~ "Model v1"
    assert Enum.any?(Record.entries(), &(&1.kind == "model"))

    # The context the driver built is a rebuild from the verbatim record.
    assert [%{user: ctx}] = StubClient.calls()
    assert ctx =~ "Design a settings page"
  end

  test "a premature sharp declaration is gated by the record" do
    StubClient.set_replies([
      reply(%{"messages" => ["The model reads sharp."], "questions" => [], "model" => nil, "artifact" => nil, "sharp" => true})
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert applied.sharp_requested
    refute applied.sharp
    refute Record.sharp?()
  end

  test "sharpness lands after three load-bearing hits and no open frontier" do
    for key <- ["one", "two", "three"] do
      {:ok, _} = Record.post_question("ai", TestSupport.question(key))
      {:ok, _} = Record.answer_question(key, %{"choice" => "alpha"}, "human")
    end

    assert Record.sharpness_ready?()

    StubClient.set_replies([
      reply(%{"messages" => ["The model reads sharp. Commit when ready, or say keep asking."], "questions" => [], "model" => nil, "artifact" => nil, "sharp" => true})
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert applied.sharp
    assert Record.sharp?()
  end

  test "natural chat can skip one question and strike another in one turn" do
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))
    {:ok, _} = Record.post_question("ai", TestSupport.question("density"))

    message = "Skip the layout question for now. The density axis is out of scope — do not ask it in any form."
    {:ok, _} = Record.post_message("human", message)

    StubClient.set_replies([
      reply(%{
        "messages" => ["Done."],
        "actions" => [
          %{"action" => "skip", "question_key" => "layout", "evidence" => "Skip the layout question for now."},
          %{"action" => "strike", "question_key" => "density", "evidence" => "The density axis is out of scope"}
        ],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert length(applied.actions) == 2
    assert Record.question_view("layout").state == :skipped
    assert Record.question_view("density").state == :struck
    assert Enum.filter(Record.entries(), &(&1.kind == "score")) == []

    skip = Enum.find(Record.entries(), &(&1.kind == "skip"))
    strike = Enum.find(Record.entries(), &(&1.kind == "strike"))
    assert skip.body == message
    assert strike.body == message
  end

  test "a chat action with invented evidence is dropped" do
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))
    {:ok, _} = Record.post_message("human", "I am still thinking about layout.")

    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "actions" => [
          %{"action" => "strike", "question_key" => "layout", "evidence" => "out of scope"}
        ],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert applied.actions == []
    assert Record.question_view("layout").state == :open
  end

  test "a provisional score is judged by the next AI turn" do
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))

    {:ok, %{score: provisional}} =
      Record.answer_question(
        "layout",
        %{"choice" => "alpha", "comment" => "alpha, but only for this page"},
        "human"
      )

    assert provisional.payload["provisional"]

    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "score_judgements" => [
          %{"question_key" => "layout", "result" => "miss", "reason" => "comment"}
        ],
        "questions" => [],
        "model" => "# Model\n- Layout: alpha only for this page.",
        "artifact" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert length(applied.score_judgements) == 1
    assert Record.question_view("layout").score["result"] == "miss"
    assert Record.question_view("layout").score["reason"] == "comment"
    refute Record.question_view("layout").score["provisional"]
  end

  test "a struck axis cannot return under a new question key" do
    {:ok, _} = Record.post_question("ai", TestSupport.question("density"))
    {:ok, _} = Record.strike_question("density", "human")

    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "questions" => [question_json("visual_density") |> Map.put("axis", "density")],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert applied.questions == []
    assert Record.question_view("visual_density") == nil
  end

  test "a non-JSON reply fails the turn and writes nothing" do
    before = length(Record.entries())
    StubClient.set_replies(["I am not JSON at all"])
    assert {:error, :reply_not_json} = Driver.run_turn()
    assert length(Record.entries()) == before
  end

  test "a gateway failure leaves the record untouched and usable" do
    StubClient.set_replies([])
    assert {:error, :no_stub_reply} = Driver.run_turn()
    # The record still takes human writes — the Project is a record first.
    assert {:ok, _} = Record.post_message("human", "still here")
  end

  test "a failed turn after a chat message appends no AI or action entries" do
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))
    {:ok, _} = Record.post_message("human", "Skip layout for now.")
    before = Record.entries()

    StubClient.set_replies([])
    assert {:error, :no_stub_reply} = Driver.run_turn()
    assert Record.entries() == before
    assert Record.question_view("layout").state == :open
  end

  test "duplicate or invalid questions in a reply are dropped, valid ones land" do
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))

    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "questions" => [
          question_json("layout"),
          Map.put(question_json("broken"), "options", [%{"value" => "a", "label" => "A"}]),
          question_json("density")
        ],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert Enum.map(applied.questions, & &1["key"]) == ["density"]
    assert Record.question_view("density").state == :open
  end

  test "an artifact in a reply becomes a versioned file + entry" do
    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => "<!doctype html><h1>Hi</h1>"},
        "sharp" => false
      })
    ])

    assert {:ok, _} = Driver.run_turn()
    assert {:ok, "<!doctype html><h1>Hi</h1>"} = ProjectFiles.read("artifacts/index.html")
    assert Enum.any?(Record.entries(), &(&1.kind == "artifact"))
  end

  test "an artifact_patch in a reply patches the current version into a new one" do
    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => "<body><h1 id=\"hero\">Hello</h1><p>First</p></body>"},
        "sharp" => false
      }),
      reply(%{
        "messages" => ["Made the headline bigger."],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "artifact_patch" => %{
          "name" => "index",
          "find" => "<h1 id=\"hero\">Hello</h1>",
          "replace" => "<h1 id=\"hero\" class=\"big\">Hello</h1>",
          "element" => "hero"
        },
        "sharp" => false
      })
    ])

    assert {:ok, _} = Driver.run_turn()
    assert {:ok, applied} = Driver.run_turn()
    assert length(applied.patches) == 1

    html = DesignSprite.Artifacts.current_html("index")
    assert html =~ "class=\"big\""
    assert html =~ "<p>First</p>"
    assert DesignSprite.Artifacts.current_version("index") == 2

    patch_entry =
      Enum.find(Record.entries(), &(&1.kind == "artifact" and &1.payload["version"] == 2))

    assert patch_entry.payload["patch"] == true
    assert patch_entry.payload["element"] == "hero"

    # The driver's context rebuild carries the current artifact bytes,
    # so the next patch can be copied byte-for-byte.
    assert [%{user: ctx1}, %{user: ctx2}] = StubClient.calls()
    assert ctx1 =~ "(no artifacts yet)"
    assert ctx2 =~ "<h1 id=\"hero\">Hello</h1>"
  end

  test "a patch with a missing or ambiguous target is dropped; the rest of the turn lands" do
    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => "<body><p>First</p></body>"},
        "sharp" => false
      }),
      reply(%{
        "messages" => ["Still here."],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "artifact_patch" => %{"name" => "index", "find" => "<p>Not there</p>", "replace" => "<p>X</p>", "element" => nil},
        "sharp" => false
      })
    ])

    assert {:ok, _} = Driver.run_turn()
    assert {:ok, applied} = Driver.run_turn()
    assert applied.patches == []
    assert DesignSprite.Artifacts.current_version("index") == 1
    assert Enum.any?(Record.entries(), &(&1.kind == "message" and &1.body == "Still here."))
  end

  test "a full artifact for the same name supersedes a patch in the same reply" do
    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => "<body><p>First</p></body>"},
        "sharp" => false
      }),
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => "<body><p>Brand new direction</p></body>"},
        "artifact_patch" => %{"name" => "index", "find" => "<p>First</p>", "replace" => "<p>Patched</p>", "element" => nil},
        "sharp" => false
      })
    ])

    assert {:ok, _} = Driver.run_turn()
    assert {:ok, applied} = Driver.run_turn()
    assert applied.patches == []
    assert DesignSprite.Artifacts.current_html("index") =~ "Brand new direction"
    assert DesignSprite.Artifacts.current_version("index") == 2
  end

  test "a hung turn is killed at the hard cap and surfaces as failed, record untouched" do
    Application.put_env(:design_sprite, :driver_turn_timeout_ms, 50)

    on_exit(fn -> Application.delete_env(:design_sprite, :driver_turn_timeout_ms) end)

    StubClient.set_replies([
      {:sleep, 500,
       %{"messages" => ["too late"], "questions" => [], "model" => nil, "artifact" => nil, "sharp" => false}}
    ])

    before = length(Record.entries())
    Driver.kick()

    assert TestSupport.eventually(fn -> Driver.status().state == :failed end)
    assert Driver.status().last_error == :turn_timeout
    assert length(Record.entries()) == before

    # Give the killed task's would-be reply window time to pass:
    # nothing from it may land late.
    Process.sleep(600)
    assert length(Record.entries()) == before
  end

  # ----------------------------------------------------------------
  # Phase 5 fixes

  defp answer_with_comment(key \\ "layout") do
    {:ok, _} = Record.post_question("ai", TestSupport.question(key))

    {:ok, %{score: score}} =
      Record.answer_question(
        key,
        %{"choice" => "alpha", "comment" => "alpha, but only for this page"},
        "human"
      )

    assert score.payload["provisional"]
    :ok
  end

  test "F1: a reply that ignores a pending provisional is corrected within the turn" do
    answer_with_comment()

    StubClient.set_replies([
      reply(%{
        "messages" => ["The layout hit stands."],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      }),
      reply(%{
        "messages" => [],
        "score_judgements" => [
          %{"question_key" => "layout", "result" => "hit", "reason" => "comment_reviewed"}
        ],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert length(applied.score_judgements) == 1
    assert applied.unresolved_provisional == []
    refute applied.degraded
    assert Record.question_view("layout").score["reason"] == "comment_reviewed"
    refute Record.question_view("layout").score["provisional"]

    # Two model calls: the turn, then the in-turn correction naming the debt.
    assert [%{user: _first}, %{user: correction}] = StubClient.calls()
    assert correction =~ "CORRECTION"
    assert correction =~ "layout"
  end

  test "F1: a provisional still unjudged after the correction degrades the turn visibly" do
    answer_with_comment()

    ignore =
      reply(%{
        "messages" => ["Moving on."],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })

    StubClient.set_replies([ignore, ignore])

    output =
      capture_io(fn ->
        assert {:ok, applied} = Driver.run_turn()
        assert applied.unresolved_provisional == ["layout"]
        assert applied.degraded
      end)

    assert output =~ "\"event\":\"ai.turn\""
    assert output =~ "\"result\":\"degraded\""
    assert output =~ "\"unresolved_provisional\":1"
    # The record is never faked into closure: still provisional.
    assert Record.question_view("layout").score["provisional"]
  end

  test "F2: an announced-but-missing question is caught by the declared count and corrected" do
    StubClient.set_replies([
      reply(%{
        "messages" => ["Two new questions: layout, and density."],
        "questions_posted" => 2,
        "questions" => [question_json("layout")],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      }),
      reply(%{
        "messages" => [],
        "questions_posted" => 1,
        "questions" => [question_json("density")],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert Enum.map(applied.questions, & &1["key"]) == ["layout", "density"]
    assert Record.question_view("layout").state == :open
    assert Record.question_view("density").state == :open
    assert applied.question_mismatch == nil
    refute applied.degraded

    assert [%{user: _first}, %{user: correction}] = StubClient.calls()
    assert correction =~ "CORRECTION"
  end

  test "F2: a count mismatch that survives the correction degrades the turn" do
    StubClient.set_replies([
      reply(%{
        "messages" => ["Two new questions."],
        "questions_posted" => 2,
        "questions" => [question_json("layout")],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      }),
      reply(%{
        "messages" => ["Still two."],
        "questions_posted" => 2,
        "questions" => [question_json("density")],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })
    ])

    output =
      capture_io(fn ->
        assert {:ok, applied} = Driver.run_turn()
        assert applied.degraded
        assert %{declared: 2, emitted: 1} = applied.question_mismatch
      end)

    assert output =~ "\"result\":\"degraded\""
    assert output =~ "\"question_mismatch\":1"
  end

  test "F4: an id-less artifact is rejected, the turn corrects it, the rest of the turn landed" do
    StubClient.set_replies([
      reply(%{
        "messages" => ["Here is a first draft."],
        "questions" => [question_json("layout")],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => @big_no_ids},
        "sharp" => false
      }),
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => @big_with_ids},
        "sharp" => false
      })
    ])

    assert {:ok, applied} = Driver.run_turn()
    assert applied.artifacts_rejected == 1
    refute applied.degraded
    assert DesignSprite.Artifacts.current_version("index") == 1
    assert DesignSprite.Artifacts.current_html("index") =~ "id=\"hero\""
    assert Record.question_view("layout").state == :open

    assert Enum.any?(
             Record.entries(),
             &(&1.kind == "message" and &1.body == "Here is a first draft.")
           )
  end

  test "F4: an id-less artifact that is never corrected stays out of the record and degrades the turn" do
    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => @big_no_ids},
        "sharp" => false
      }),
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "sharp" => false
      })
    ])

    output =
      capture_io(fn ->
        assert {:ok, applied} = Driver.run_turn()
        assert applied.artifacts_rejected == 1
        assert applied.degraded
      end)

    assert output =~ "\"artifacts_rejected\":1"
    assert DesignSprite.Artifacts.current_html("index") == nil
    assert Enum.filter(Record.entries(), &(&1.kind == "artifact")) == []
  end

  test "F4: a patch whose replacement introduces id-less structure is dropped, then corrected" do
    seed =
      "<body><header id=\"top\"><h1 id=\"hero\">Hello</h1></header>" <>
        "<main id=\"main\"><p id=\"note\">First</p></main></body>"

    fragment =
      "<section><h2>New</h2><p>One.</p><p>Two.</p><a href=\"/x\">X</a></section>"

    fragment_ids =
      "<section id=\"new\"><h2 id=\"new-h\">New</h2><p>One.</p><p>Two.</p>" <>
        "<a id=\"new-x\" href=\"/x\">X</a></section>"

    StubClient.set_replies([
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => %{"name" => "index", "html" => seed},
        "sharp" => false
      }),
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "artifact_patch" => %{
          "name" => "index",
          "find" => "<p id=\"note\">First</p>",
          "replace" => fragment,
          "element" => "note"
        },
        "sharp" => false
      }),
      reply(%{
        "messages" => [],
        "questions" => [],
        "model" => nil,
        "artifact" => nil,
        "artifact_patch" => %{
          "name" => "index",
          "find" => "<p id=\"note\">First</p>",
          "replace" => fragment_ids,
          "element" => "note"
        },
        "sharp" => false
      })
    ])

    assert {:ok, _} = Driver.run_turn()

    assert {:ok, applied} = Driver.run_turn()
    assert length(applied.patches) == 1
    assert applied.artifacts_rejected == 1
    refute applied.degraded
    assert DesignSprite.Artifacts.current_version("index") == 2
    assert DesignSprite.Artifacts.current_html("index") =~ "id=\"new\""
  end

  test "F5: a provider-shaped client error returns untouched and writes nothing" do
    before = length(Record.entries())

    StubClient.set_replies([
      {:error, {:ai_call_failed, %{"error" => %{"type" => "invalid_request_error"}}}}
    ])

    assert {:error, {:ai_call_failed, _}} = Driver.run_turn()
    assert length(Record.entries()) == before
  end

  test "kick runs a turn asynchronously and updates driver status" do
    StubClient.set_replies([
      reply(%{"messages" => ["hi"], "questions" => [], "model" => nil, "artifact" => nil, "sharp" => false})
    ])

    Driver.kick()

    assert TestSupport.eventually(fn ->
             Enum.any?(Record.entries(), &(&1.kind == "message" and &1.body == "hi"))
           end)

    assert TestSupport.eventually(fn -> Driver.status().state == :idle end)
  end
end
