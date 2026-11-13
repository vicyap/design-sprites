defmodule DesignSpriteWeb.LiveTest do
  use DesignSpriteWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DesignSprite.{Record, TestSupport}
  alias DesignSprite.AI.StubClient

  test "opening screen asks the one question; beginning creates the Project", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "What do you want to design?"

    view
    |> form(".opening-card form", %{want: "A pricing page for a small gym"})
    |> render_submit()

    assert render(view) =~ "A pricing page for a small gym"
    assert %DesignSprite.Resources.Project{} = Record.project()
  end

  test "question cards render; answering in the pane lands the answer + score", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))
    StubClient.set_replies([~s({"messages":["Noted."],"questions":[],"model":null,"artifact":null,"sharp":false})])

    {:ok, view, _html} = live(conn, "/")
    assert render(view) =~ "Question layout?"

    view |> element(".qcard button", "Answer") |> render_click()
    assert render(view) =~ "Alpha"

    view |> element(".option-row", "Alpha") |> render_click()

    html = render(view)
    assert html =~ "Alpha"
    assert html =~ "prediction hit"
    assert Record.question_view("layout").state == :answered
  end

  test "a preview dial value submitted through the pane lands verbatim", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")

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
    StubClient.set_replies([~s({"messages":[],"questions":[],"model":null,"artifact":null,"sharp":false})])

    {:ok, view, _html} = live(conn, "/")
    view |> element(".qcard button", "Answer") |> render_click()

    view
    |> form("#answer-form-density_dial", %{answer: %{"choice" => "18"}})
    |> render_submit()

    view = Record.question_view("density_dial")
    assert view.state == :answered
    assert view.answer["dialed_value"] == "18"
    assert view.score["result"] == "hit"
  end

  test "a chat message lands in the record verbatim", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")
    StubClient.set_replies([~s({"messages":[],"questions":[],"model":null,"artifact":null,"sharp":false})])

    {:ok, view, _html} = live(conn, "/")

    view
    |> form(".composer", %{message: %{text: "Keep it to one screen, please."}})
    |> render_submit()

    assert Enum.any?(Record.entries(), &(&1.kind == "message" and &1.body == "Keep it to one screen, please."))
    assert render(view) =~ "Keep it to one screen, please."
  end

  test "a preview question renders its variants as sandboxed frames, with a dial when it has dial stops", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")

    q =
      TestSupport.question("density_dial", %{
        "type" => "preview",
        "options" => [
          %{"value" => "12", "label" => "12 px", "preview" => "<p style=\"font-size:12px\">Aa</p>"},
          %{"value" => "18", "label" => "18 px", "preview" => "<p style=\"font-size:18px\">Aa</p>"},
          %{"value" => "24", "label" => "24 px", "preview" => "<p style=\"font-size:24px\">Aa</p>"}
        ],
        "prediction" => "18"
      })

    {:ok, _} = Record.post_question("ai", q)

    {:ok, view, _html} = live(conn, "/")
    view |> element(".qcard button", "Answer") |> render_click()

    html = render(view)
    assert html =~ "variant-matrix"
    # Each variant preview is its own sandboxed frame (no style bleed,
    # no script execution), one full-width card per option.
    assert length(String.split(html, "srcdoc=")) - 1 == 3
    assert html =~ "sandbox=\"\""
    # Numeric stops ARE dial stops: the slider + dialed value field show.
    assert html =~ "type=\"range\""
    assert html =~ "answer[dialed_value]"
    assert html =~ "phx-hook=\"Dial\""
  end

  test "a preview question without dial stops renders NO dial input", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")

    q =
      TestSupport.question("layout_style", %{
        "type" => "preview",
        "options" => [
          %{"value" => "stacked", "label" => "Stacked", "preview" => "<p>Stacked</p>"},
          %{"value" => "grid", "label" => "Grid", "preview" => "<p>Grid</p>"}
        ],
        "prediction" => "stacked"
      })

    {:ok, _} = Record.post_question("ai", q)

    {:ok, view, _html} = live(conn, "/")
    view |> element(".qcard button", "Answer") |> render_click()

    html = render(view)
    assert html =~ "variant-matrix"
    # Non-numeric option values are not dial stops — no dial at all.
    refute html =~ "answer[dialed_value]"
    refute html =~ "type=\"range\""
    refute html =~ "phx-hook=\"Dial\""
  end

  test "preview variants stack vertically and the composer follows the chat column (CSS)", %{conn: _conn} do
    css = File.read!(Path.join([File.cwd!(), "priv", "static", "app.css"]))

    # Stacked, full-width preview cards (no auto-fit side-by-side grid).
    assert css =~ ".variant-matrix"
    assert css =~ "flex-direction: column"
    refute css =~ "repeat(auto-fit"

    # The composer is capped at the chat column's 65ch, centered with
    # the pane closed and left-aligned (margin 0) when it opens.
    assert css =~ ".shell-pane .composer { margin: 0; }"
    composer_block = css |> String.split(".composer {") |> Enum.at(1) |> String.split("}") |> hd()
    assert composer_block =~ "max-width: 65ch"
    assert composer_block =~ "margin: 0 auto"
  end

  test "an answered question can be re-answered from the pane — latest wins, history kept", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")
    {:ok, _} = Record.post_question("ai", TestSupport.question("layout"))
    StubClient.set_replies([~s({"messages":[],"questions":[],"model":null,"artifact":null,"sharp":false})])

    {:ok, view, _html} = live(conn, "/")
    view |> element(".qcard button", "Answer") |> render_click()
    view |> element(".option-row", "Alpha") |> render_click()
    assert Record.question_view("layout").score["result"] == "hit"

    # The answered card offers the edit; the pane reopens pre-filled.
    assert render(view) =~ "Change answer"
    view |> element("button", "Change answer") |> render_click()
    assert render(view) =~ "Save changed answer"

    view |> element(".option-row", "Beta") |> render_click()

    view_state = Record.question_view("layout")
    assert view_state.answer["choice"] == "beta"
    assert view_state.answer["superseding"] == true
    assert view_state.score["result"] == "miss"
    assert Record.tally() == %{hits: 0, misses: 1, answered: 1, open: 0, skipped: 0, struck: 0}
    assert length(Enum.filter(Record.entries(), &(&1.kind == "answer"))) == 2
  end

  test "a dialed value typed in the pane is the answer, verbatim, even between stops", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")

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
    StubClient.set_replies([~s({"messages":[],"questions":[],"model":null,"artifact":null,"sharp":false})])

    {:ok, view, _html} = live(conn, "/")
    view |> element(".qcard button", "Answer") |> render_click()

    view
    |> form("#answer-form-density_dial", %{answer: %{"dialed_value" => "20"}})
    |> render_submit()

    view_state = Record.question_view("density_dial")
    assert view_state.state == :answered
    assert view_state.answer["dialed_value"] == "20"
    assert view_state.answer["choice"] == "other"
    assert view_state.score["result"] == "miss"
  end

  test "clicking an artifact element attaches it to the composer and the message carries it", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")
    StubClient.set_replies([~s({"messages":[],"questions":[],"model":null,"artifact":null,"sharp":false})])

    {:ok, view, _html} = live(conn, "/")

    # This is the event the artifact iframe's bridge produces via the
    # Composer hook when the Driver clicks an element.
    render_hook(view, "attach_element", %{
      "element" => %{
        "tag" => "h1",
        "id" => "hero-title",
        "classes" => "big",
        "text" => "Welcome in",
        "path" => "body > h1",
        "snippet" => "<h1 id=\"hero-title\">Welcome in</h1>",
        "artifact" => "index"
      }
    })

    assert render(view) =~ "h1#hero-title"

    view
    |> form(".composer", %{message: %{text: "Make this headline warmer."}})
    |> render_submit()

    message = Enum.find(Record.entries(), &(&1.kind == "message" and &1.actor == "human"))
    assert [el] = message.payload["elements"]
    assert el["id"] == "hero-title"
    assert el["path"] == "body > h1"
    assert el["artifact"] == "index"

    # The verbatim rebuild the AI reads shows the attachment, so its
    # next patch can target the element.
    assert Record.transcript_text() =~ "attached: h1#hero-title"
  end

  test "a page snapshot pasted in the pane enters as artifact version 0", %{conn: conn} do
    {:ok, _} = Record.create_project("Redesign the pricing page")

    {:ok, view, _html} = live(conn, "/")
    view |> element("button", "Add a page snapshot") |> render_click()

    view
    |> form(".snapshot-form", %{
      snapshot: %{name: "current-pricing", html: "<!doctype html><body><h1>Old pricing</h1></body>"}
    })
    |> render_submit()

    assert DesignSprite.Artifacts.current_version("current-pricing") == 0
    assert DesignSprite.Artifacts.current_html("current-pricing") =~ "Old pricing"

    entry = Enum.find(Record.entries(), &(&1.kind == "artifact"))
    assert entry.payload["snapshot"] == true
    assert render(view) =~ "current-pricing"
  end

  test "after commit the composer is gone and the record refuses writes", %{conn: conn} do
    {:ok, _} = Record.create_project("Design a settings page")
    {:ok, view, _html} = live(conn, "/")

    view |> element("button", "Commit") |> render_click()
    assert render(view) =~ "Commit locks this Project"
    view |> element("button", "Confirm commit") |> render_click()

    assert render(view) =~ "read-only"
    assert {:error, :committed} = Record.post_message("human", "too late")
  end
end
