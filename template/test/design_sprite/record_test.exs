defmodule DesignSprite.RecordTest do
  use ExUnit.Case, async: false

  alias DesignSprite.{Record, TestSupport}

  setup do
    TestSupport.wipe!()
    {:ok, _project} = Record.create_project("Design a settings page")
    :ok
  end

  defp ask(key, overrides \\ %{}) do
    {:ok, entry} = Record.post_question("ai", TestSupport.question(key, overrides))
    entry
  end

  defp answer(key, attrs) do
    Record.answer_question(key, attrs, "human")
  end

  test "the want is the first entry and the project exists" do
    assert %DesignSprite.Resources.Project{want: "Design a settings page"} = Record.project()
    assert [%{kind: "want", body: "Design a settings page"} | _] = Record.entries()
  end

  test "a second project is refused" do
    assert {:error, :project_exists} = Record.create_project("Another")
  end

  test "prediction match with no comment is a clean hit" do
    ask("layout")
    assert {:ok, %{score: score}} = answer("layout", %{"choice" => "alpha"})
    assert score.payload["result"] == "hit"
    assert score.payload["reason"] == "choice_match"
    assert score.payload["provisional"] == false
    assert Record.tally().hits == 1
  end

  test "a different choice is a miss; Other is a miss" do
    ask("layout")
    assert {:ok, %{score: s1}} = answer("layout", %{"choice" => "beta"})
    assert s1.payload["result"] == "miss"

    ask("density")
    assert {:ok, %{score: s2}} = answer("density", %{"choice" => "other", "other_text" => "Neither"})
    assert s2.payload["result"] == "miss"
    assert s2.payload["reason"] == "other"
  end

  test "a comment makes the score provisional until judged" do
    ask("layout")

    assert {:ok, %{score: score}} =
             answer("layout", %{"choice" => "alpha", "comment" => "alpha, but denser"})

    assert score.payload["provisional"] == true

    # The AI judges the comment build-changing: a superseding miss.
    assert {:ok, judged} = Record.supersede_score("layout", "miss", "comment", "ai")
    assert judged.payload["provisional"] == false
    assert Record.tally() == %{hits: 0, misses: 1, answered: 1, open: 0, skipped: 0, struck: 0}
  end

  test "skip records no score, leaves the prediction standing, and the question can still be answered" do
    ask("layout")
    assert {:ok, _} = Record.skip_question("layout", "human")
    assert Record.question_view("layout").state == :skipped
    assert Record.tally().answered == 0
    assert Enum.filter(Record.entries(), &(&1.kind == "score")) == []

    assert {:ok, _} = answer("layout", %{"choice" => "alpha"})
    assert Record.question_view("layout").state == :answered
  end

  test "strike is terminal and removes the axis" do
    ask("layout")
    assert {:ok, _} = Record.strike_question("layout", "human")
    assert Record.question_view("layout").state == :struck
    assert {:error, :question_struck} = answer("layout", %{"choice" => "alpha"})
    assert Record.tally().struck == 1
  end

  test "answering twice is refused — the record never overwrites a word" do
    ask("layout")
    assert {:ok, _} = answer("layout", %{"choice" => "alpha"})
    assert {:error, :already_answered} = answer("layout", %{"choice" => "beta"})

    answers = Enum.filter(Record.entries(), &(&1.kind == "answer"))
    assert length(answers) == 1
    assert hd(answers).payload["choice"] == "alpha"
  end

  test "Other without text is refused" do
    ask("layout")
    assert {:error, :other_text_required} = answer("layout", %{"choice" => "other", "other_text" => " "})
  end

  test "multi answers score on the whole set" do
    q =
      TestSupport.question("features", %{
        "type" => "multi",
        "options" => [
          %{"value" => "a", "label" => "A"},
          %{"value" => "b", "label" => "B"},
          %{"value" => "c", "label" => "C"}
        ],
        "prediction" => ["a", "c"]
      })

    {:ok, _} = Record.post_question("ai", q)
    assert {:ok, %{score: s}} = answer("features", %{"choices" => ["c", "a"]})
    assert s.payload["result"] == "hit"

    ask("extras", %{"type" => "multi", "prediction" => ["alpha"]})
    assert {:ok, %{score: s2}} = answer("extras", %{"choices" => ["alpha", "other"], "other_text" => "plus one more"})
    assert s2.payload["result"] == "miss"
  end

  test "question validation rejects malformed cards" do
    assert {:error, :question_options_count} =
             Record.post_question("ai", TestSupport.question("x", %{"options" => [%{"value" => "a", "label" => "A"}]}))

    assert {:error, :prediction_not_an_option} =
             Record.post_question("ai", TestSupport.question("x", %{"prediction" => "gamma"}))

    assert {:error, :question_load_bearing_invalid} =
             Record.post_question("ai", TestSupport.question("x", %{"load_bearing" => "yes"}))

    assert {:error, :question_preview_required} =
             Record.post_question(
               "ai",
               TestSupport.question("preview_without_previews", %{"type" => "preview"})
             )
  end

  test "a preview dial answer carries the dialed stop verbatim" do
    q =
      TestSupport.question("density_dial", %{
        "type" => "preview",
        "options" => [
          %{"value" => "12", "label" => "12 px", "preview" => "<p>12</p>"},
          %{"value" => "18", "label" => "18 px", "preview" => "<p>18</p>"},
          %{"value" => "24", "label" => "24 px", "preview" => "<p>24</p>"}
        ],
        "prediction" => "18"
      })

    {:ok, _} = Record.post_question("ai", q)

    assert {:ok, %{answer: answer, score: score}} =
             Record.answer_question("density_dial", %{"dialed_value" => "18"}, "human")

    assert answer.payload["choice"] == "18"
    assert answer.payload["dialed_value"] == "18"
    assert score.payload["result"] == "hit"
    assert Record.transcript_text() =~ "dialed: 18"
  end

  test "a free-dialed preview value is preserved as the Other text" do
    q =
      TestSupport.question("radius_dial", %{
        "type" => "preview",
        "options" => [
          %{"value" => "8", "label" => "8 px", "preview" => "<p>8</p>"},
          %{"value" => "16", "label" => "16 px", "preview" => "<p>16</p>"}
        ],
        "prediction" => "8"
      })

    {:ok, _} = Record.post_question("ai", q)

    assert {:ok, %{answer: answer, score: score}} =
             Record.answer_question("radius_dial", %{"dialed_value" => "12.5"}, "human")

    assert answer.payload["choice"] == "other"
    assert answer.payload["other_text"] == "12.5"
    assert answer.payload["dialed_value"] == "12.5"
    assert score.payload["reason"] == "other"
  end

  test "the sharpness gate needs three recent final load-bearing hits and no blockers" do
    for key <- ["one", "two", "three"] do
      ask(key)
    end

    refute Record.sharpness_ready?()
    assert {:ok, _} = answer("one", %{"choice" => "alpha"})
    assert {:ok, _} = answer("two", %{"choice" => "alpha"})
    refute Record.sharpness_ready?()
    assert {:ok, _} = answer("three", %{"choice" => "alpha"})
    assert Record.sharpness_ready?()

    # A later miss breaks the recent run until three more hits land.
    ask("four")
    assert {:ok, _} = answer("four", %{"choice" => "beta"})
    refute Record.sharpness_ready?()
  end

  test "a skipped load-bearing question blocks sharpness until it is struck" do
    for key <- ["one", "two", "three"] do
      ask(key)
      assert {:ok, _} = answer(key, %{"choice" => "alpha"})
    end

    ask("extra")
    assert {:ok, _} = Record.skip_question("extra", "human", "skip this one")
    assert Record.question_view("extra").state == :skipped
    refute Record.sharpness_ready?()

    assert {:ok, _} = Record.strike_question("extra", "human")
    assert Record.sharpness_ready?()
  end

  test "drafts persist as mutable scratch and clear on answer" do
    ask("layout")
    assert {:ok, _} = Record.save_draft("layout", %{"comment" => "half-typed thou"})
    assert Record.draft("layout").payload["comment"] == "half-typed thou"

    assert {:ok, _} = Record.save_draft("layout", %{"comment" => "half-typed thought"})
    assert Record.draft("layout").payload["comment"] == "half-typed thought"

    assert {:ok, _} = answer("layout", %{"choice" => "alpha"})
    assert Record.draft("layout") == nil
  end

  test "commit freezes design content; decisions still append" do
    ask("layout")
    assert {:ok, project} = Record.commit("human")
    assert project.status == "committed"
    assert Record.committed?()

    assert {:error, :committed} = Record.post_message("human", "one more thought")
    assert {:error, :committed} = answer("layout", %{"choice" => "alpha"})
    assert {:ok, _} = Record.append_decision("agent", "Used the model's density line; chose compact.")
    assert {:error, :already_committed} = Record.commit("human")
  end

  test "sharpness is derived from the latest sharp/resume marker" do
    refute Record.sharp?()
    assert {:ok, _} = Record.declare_sharp("ai")
    assert Record.sharp?()
    assert {:ok, _} = Record.resume()
    refute Record.sharp?()
  end

  test "the transcript renders questions, answers and scores verbatim" do
    ask("layout")
    assert {:ok, _} = answer("layout", %{"choice" => "beta", "comment" => "too airy"})
    text = Record.transcript_text()
    assert text =~ "Question layout?"
    assert text =~ "choice: beta"
    assert text =~ "too airy"
    assert text =~ "score(layout): miss"
  end
end
