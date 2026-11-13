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

  test "a preview question renders its variants side by side as sandboxed frames, with a dial", %{conn: conn} do
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
    # no script execution), presented side by side in the matrix.
    assert length(String.split(html, "srcdoc=")) - 1 == 3
    assert html =~ "sandbox=\"\""
    # Numeric stops get a slider; the dialed value field rides along.
    assert html =~ "type=\"range\""
    assert html =~ "answer[dialed_value]"
    assert html =~ "phx-hook=\"Dial\""
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
