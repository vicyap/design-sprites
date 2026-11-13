defmodule DesignSpriteWeb.ProjectLive do
  @moduledoc """
  The Project screen: one chat thread, a left navigator, and a right
  pane that opens for questions, the artifact, and files. Chat sits
  centered until the pane opens, then shifts left (contract item 3).

  The Driver seat: the first visitor auto-claims it when free; the
  lock dies with the Driver's LiveView (presence-bound). Viewers watch
  everything live and can take the wheel when it frees up.
  """

  use DesignSpriteWeb, :live_view

  alias DesignSprite.{DriverLock, Markdown, ProjectFiles, Record}
  alias DesignSprite.AI.Driver
  alias DesignSpriteWeb.Presence

  # ----------------------------------------------------------------
  # Mount / state loading

  @impl true
  def mount(_params, _session, socket) do
    visitor_id = "web-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    socket =
      socket
      |> assign(:visitor_id, visitor_id)
      |> assign(:pane, nil)
      |> assign(:chips, [])
      |> assign(:strike_arm, nil)
      |> assign(:commit_arm, false)
      |> assign(:nav_open, false)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DesignSprite.PubSub, "project")
      Phoenix.PubSub.subscribe(DesignSprite.PubSub, Presence.topic())

      {:ok, _} =
        Presence.track(self(), Presence.topic(), visitor_id, %{role: "viewer"})

      maybe_claim(socket)
    end

    {:ok, load_all(socket)}
  end

  defp maybe_claim(socket) do
    if DriverLock.holder() == nil do
      case DriverLock.acquire(socket.assigns.visitor_id, self()) do
        :ok ->
          Presence.update(self(), Presence.topic(), socket.assigns.visitor_id, %{
            role: "driver"
          })

        _ ->
          :ok
      end
    end

    :ok
  end

  defp load_all(socket) do
    project = Record.project()
    holder = DriverLock.holder()

    socket
    |> assign(:project, project)
    |> assign(:entries, Record.entries())
    |> assign(:views, Record.question_views())
    |> assign(:drafts, Record.drafts())
    |> assign(:files, ProjectFiles.list())
    |> assign(:model_text, ProjectFiles.model_text())
    |> assign(:tally, Record.tally())
    |> assign(:sharp, Record.sharp?())
    |> assign(:driver_status, Driver.status())
    |> assign(:driver_id, holder)
    |> assign(:am_driver, holder == socket.assigns.visitor_id)
    |> assign(:watchers, Presence.list(Presence.topic()) |> map_size())
  end

  # ----------------------------------------------------------------
  # Live updates

  @impl true
  def handle_info({:entry_appended, _entry}, socket) do
    {:noreply, load_all(socket)}
  end

  def handle_info({:driver_status, status}, socket) do
    {:noreply, assign(socket, :driver_status, status)}
  end

  def handle_info(:driver_released, socket) do
    maybe_claim(socket)
    {:noreply, load_all(socket)}
  end

  def handle_info(%{event: "presence_diff"}, socket) do
    {:noreply,
     socket
     |> assign(:watchers, Presence.list(Presence.topic()) |> map_size())
     |> assign(:driver_id, DriverLock.holder())
     |> assign(:am_driver, DriverLock.holder() == socket.assigns.visitor_id)}
  end

  # ----------------------------------------------------------------
  # Events

  @impl true
  def handle_event("begin", %{"want" => want}, socket) do
    case Record.create_project(want) do
      {:ok, _project} ->
        Driver.kick()
        {:noreply, load_all(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That needs a sentence about what you want to design.")}
    end
  end

  def handle_event("send_message", %{"message" => %{"text" => text}}, socket) do
    text = String.trim(text || "")

    cond do
      not socket.assigns.am_driver ->
        {:noreply, put_flash(socket, :error, "Take the wheel to drive this Project.")}

      text == "" and socket.assigns.chips == [] ->
        {:noreply, socket}

      true ->
        case Record.post_message("human", text, socket.assigns.chips) do
          {:ok, _} ->
            Driver.kick()
            {:noreply, socket |> assign(:chips, []) |> load_all()}

          {:error, :committed} ->
            {:noreply, put_flash(socket, :error, "This Project is committed and read-only.")}
        end
    end
  end

  def handle_event("claim_driver", _params, socket) do
    case DriverLock.acquire(socket.assigns.visitor_id, self()) do
      :ok ->
        Presence.update(self(), Presence.topic(), socket.assigns.visitor_id, %{role: "driver"})
        {:noreply, load_all(socket)}

      {:error, :held, _other} ->
        {:noreply, put_flash(socket, :error, "Someone else is driving right now.")}
    end
  end

  def handle_event("release_driver", _params, socket) do
    DriverLock.release(socket.assigns.visitor_id)
    Presence.update(self(), Presence.topic(), socket.assigns.visitor_id, %{role: "viewer"})
    {:noreply, load_all(socket)}
  end

  def handle_event("toggle_nav", _params, socket) do
    {:noreply, assign(socket, :nav_open, not socket.assigns.nav_open)}
  end

  def handle_event("open_question", %{"key" => key}, socket) do
    {:noreply, socket |> assign(:pane, {:question, key}) |> assign(:strike_arm, nil)}
  end

  def handle_event("open_artifact", %{"name" => name}, socket) do
    {:noreply, assign(socket, :pane, {:artifact, name, :latest})}
  end

  def handle_event("open_artifact_version", %{"name" => name, "version" => version}, socket) do
    case Integer.parse(version) do
      {n, ""} when n >= 0 -> {:noreply, assign(socket, :pane, {:artifact, name, n})}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_snapshot", _params, socket) do
    {:noreply, assign(socket, :pane, :snapshot)}
  end

  def handle_event("add_snapshot", %{"snapshot" => %{"name" => name, "html" => html}}, socket) do
    if not socket.assigns.am_driver do
      {:noreply, put_flash(socket, :error, "Take the wheel to add a snapshot.")}
    else
      case Record.snapshot_artifact(name || "", html || "", "human") do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:pane, {:artifact, DesignSprite.Artifacts.sanitize_name(name), :latest})
           |> load_all()}

        {:error, :artifact_exists} ->
          {:noreply, put_flash(socket, :error, "That artifact already exists — a snapshot can only enter as version 0 of a new artifact.")}

        {:error, :snapshot_empty} ->
          {:noreply, put_flash(socket, :error, "Paste the page's HTML to snapshot it.")}

        {:error, :snapshot_name_required} ->
          {:noreply, put_flash(socket, :error, "Give the snapshot a name.")}

        {:error, :committed} ->
          {:noreply, put_flash(socket, :error, "This Project is committed and read-only.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "That snapshot could not be saved.")}
      end
    end
  end

  def handle_event("open_file", %{"path" => path}, socket) do
    {:noreply, assign(socket, :pane, {:file, path, :latest})}
  end

  def handle_event("open_file_version", %{"path" => path, "version" => version}, socket) do
    case Integer.parse(version) do
      {n, ""} when n >= 0 -> {:noreply, assign(socket, :pane, {:file, path, n})}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_explorer", _params, socket) do
    {:noreply, assign(socket, :pane, :explorer)}
  end

  def handle_event("close_pane", _params, socket) do
    {:noreply, assign(socket, :pane, nil)}
  end

  def handle_event("draft_answer", %{"answer" => form}, socket) do
    key = form["question_key"]

    if socket.assigns.am_driver and is_binary(key) and Record.question_view(key) != nil do
      Record.save_draft(key, draft_payload(form))
    end

    {:noreply, socket}
  end

  def handle_event("answer_option", %{"key" => key, "choice" => choice}, socket) do
    draft = socket.assigns.drafts[key] || %{}

    attrs = %{
      "choice" => choice,
      "choices" => nil,
      "other_text" => draft["other_text"] || "",
      "comment" => draft["comment"] || ""
    }

    do_answer(socket, key, attrs)
  end

  def handle_event("send_answer", %{"answer" => form}, socket) do
    key = form["question_key"]

    attrs = %{
      "choice" => form["choice"],
      "choices" => normalize_choices(form["choices"]),
      "other_text" => form["other_text"] || "",
      "dialed_value" => form["dialed_value"],
      "comment" => form["comment"] || ""
    }

    do_answer(socket, key, attrs)
  end

  def handle_event("skip_question", %{"key" => key}, socket) do
    if socket.assigns.am_driver do
      case Record.skip_question(key, "human") do
        {:ok, _} -> Driver.kick()
        _ -> :ok
      end
    end

    {:noreply, load_all(socket)}
  end

  def handle_event("strike_question", %{"key" => key}, socket) do
    cond do
      not socket.assigns.am_driver ->
        {:noreply, socket}

      socket.assigns.strike_arm != key ->
        {:noreply, assign(socket, :strike_arm, key)}

      true ->
        case Record.strike_question(key, "human") do
          {:ok, _} -> Driver.kick()
          _ -> :ok
        end

        {:noreply, socket |> assign(:strike_arm, nil) |> assign(:pane, nil) |> load_all()}
    end
  end

  def handle_event("attach_element", %{"element" => element}, socket) do
    chip = %{
      "tag" => element["tag"] || "element",
      "id" => element["id"] || "",
      "classes" => element["classes"] || "",
      "text" => String.slice(element["text"] || "", 0, 120),
      "path" => element["path"] || "",
      "snippet" => String.slice(element["snippet"] || "", 0, 200),
      "artifact" => element["artifact"] || ""
    }

    {:noreply, assign(socket, :chips, socket.assigns.chips ++ [chip])}
  end

  def handle_event("remove_chip", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    {:noreply, assign(socket, :chips, List.delete_at(socket.assigns.chips, idx))}
  end

  def handle_event("commit", _params, socket) do
    {:noreply, assign(socket, :commit_arm, true)}
  end

  def handle_event("commit_cancel", _params, socket) do
    {:noreply, assign(socket, :commit_arm, false)}
  end

  def handle_event("commit_confirm", _params, socket) do
    if socket.assigns.am_driver do
      case Record.commit("human") do
        {:ok, _} -> :ok
        {:error, reason} -> put_flash(socket, :error, "Could not commit: #{reason}")
      end
    end

    {:noreply, socket |> assign(:commit_arm, false) |> load_all()}
  end

  def handle_event("keep_asking", _params, socket) do
    if socket.assigns.am_driver do
      Record.resume()
      Driver.kick()
    end

    {:noreply, load_all(socket)}
  end

  defp do_answer(socket, key, attrs) do
    if not socket.assigns.am_driver do
      {:noreply, put_flash(socket, :error, "Take the wheel to answer.")}
    else
      case Record.answer_question(key, attrs, "human") do
        {:ok, _} ->
          Driver.kick()
          {:noreply, socket |> assign(:pane, nil) |> load_all()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, answer_error_text(reason))}
      end
    end
  end

  defp answer_error_text(:other_text_required), do: "Other needs the text — what is your answer?"
  defp answer_error_text(:choice_required), do: "Pick an option first."
  defp answer_error_text(:committed), do: "This Project is committed and read-only."
  defp answer_error_text(_), do: "That answer could not be saved."

  # The form values for a question: an in-progress draft wins; for an
  # already-answered question with no draft, the current (latest)
  # answer pre-fills the form so changing it starts from where it
  # stands, not from a blank card.
  defp effective_draft(%{state: :answered, answer: answer}, draft)
       when is_map(answer) and map_size(draft) == 0 do
    %{
      "choice" => answer["choice"],
      "choices" => answer["choices"],
      "other_text" => answer["other_text"],
      "dialed_value" => answer["dialed_value"],
      "comment" => answer["comment"]
    }
  end

  defp effective_draft(_view, draft), do: draft

  defp draft_payload(form) do
    %{
      "choice" => form["choice"],
      "choices" => normalize_choices(form["choices"]),
      "other_text" => form["other_text"] || "",
      "dialed_value" => form["dialed_value"],
      "comment" => form["comment"] || ""
    }
  end

  defp normalize_choices(nil), do: []
  defp normalize_choices(list) when is_list(list), do: list
  defp normalize_choices(%{} = map), do: map |> Map.values()
  defp normalize_choices(single) when is_binary(single), do: [single]

  # ----------------------------------------------------------------
  # Rendering helpers

  defp md(text), do: Phoenix.HTML.raw(Markdown.to_html(text || ""))

  defp option_label(question, value) do
    case Enum.find(question["options"] || [], &(&1["value"] == value)) do
      %{"label" => label} -> label
      _ -> value
    end
  end

  defp answer_summary(view) do
    q = view.question
    a = view.answer

    labels =
      case q["type"] do
        "multi" ->
          (a["choices"] || [])
          |> Enum.map(fn
            "other" -> "Other: #{a["other_text"]}"
            v -> option_label(q, v)
          end)

        _ ->
          [
            cond do
              q["type"] == "preview" and a["dialed_value"] not in [nil, ""] ->
                a["dialed_value"]

              a["choice"] == "other" ->
                "Other: #{a["other_text"]}"

              true ->
                option_label(q, a["choice"])
            end
          ]
      end

    Enum.join(labels, " · ")
  end

  defp score_chip(%{score: nil}), do: nil

  defp score_chip(%{score: score}) do
    %{
      text: if(score["result"] == "hit", do: "prediction hit", else: "prediction missed"),
      class: if(score["result"] == "hit", do: "chip chip-hit", else: "chip chip-miss"),
      provisional: score["provisional"] == true
    }
  end

  defp artifacts(entries) do
    entries
    |> Enum.filter(&(&1.kind == "artifact"))
    |> Enum.map(& &1.payload["name"])
    |> Enum.uniq()
  end

  defp decisions(entries) do
    Enum.filter(entries, &(&1.kind == "decision"))
  end

  defp pane_question(assigns) do
    case assigns.pane do
      {:question, key} -> Enum.find(assigns.views, &(&1.key == key))
      _ -> nil
    end
  end

  # An attached element's short label: its stable identity — the
  # element id when it has one, else its CSS path in the artifact.
  defp chip_label(el) do
    cond do
      el["id"] not in [nil, ""] -> "#{el["tag"]}##{el["id"]}"
      el["path"] not in [nil, ""] -> "#{el["tag"]} (#{el["path"]})"
      true -> el["tag"] || "element"
    end
  end

  # Dial stops for a preview question: [{value_string, number}] when
  # EVERY option value is numeric, else nil (no slider — the dialed
  # value is typed verbatim instead).
  defp numeric_stops(question) do
    options = question["options"] || []

    parsed =
      Enum.map(options, fn o ->
        case Float.parse(o["value"] || "") do
          {n, ""} -> {o["value"], n}
          _ -> nil
        end
      end)

    if options != [] and Enum.all?(parsed) do
      Enum.sort_by(parsed, &elem(&1, 1))
    else
      nil
    end
  end

  defp dial_step(stops) do
    diffs =
      stops
      |> Enum.map(&elem(&1, 1))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)
      |> Enum.filter(&(&1 > 0))

    case diffs do
      [] -> 1
      _ -> Enum.min(diffs)
    end
  end

  defp dial_initial(question, draft, stops) do
    values = Enum.map(stops, &elem(&1, 0))

    cond do
      draft["dialed_value"] in values -> draft["dialed_value"]
      question["prediction"] in values -> question["prediction"]
      true -> hd(values)
    end
  end

  # ----------------------------------------------------------------
  # Render

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @project == nil do %>
      <div class="opening">
        <div class="opening-card">
          <p class="eyebrow">New Project</p>
          <h1 class="opening-q">What do you want to design?</h1>
          <form phx-submit="begin">
            <textarea
              id="want-box"
              name="want"
              rows="3"
              phx-hook="AutoResize"
              placeholder="A landing page for… / Decide whether to…"
              class="want-box"
            ></textarea>
            <button type="submit" class="btn btn-gold">Begin designing</button>
          </form>
          <p class="opening-note">
            One Project, one chat thread. The AI asks; you answer and shape the design in the same stream.
          </p>
        </div>
      </div>
    <% else %>
      <div class={"shell" <> if(@pane, do: " shell-pane", else: "")}>
        <header class="topbar">
          <button class="icon-btn nav-toggle" phx-click="toggle_nav" aria-label="Project files">☰</button>
          <div class="brand">
            <span class="eyebrow">Design Sprite</span>
            <span class="project-name">{@project.title || @project.want}</span>
          </div>
          <div class="topbar-right">
            <span class="presence-note">
              <%= cond do %>
                <% @project.status == "committed" -> %>
                  Committed — read-only
                <% @am_driver -> %>
                  You are driving · {@watchers} here
                <% @driver_id -> %>
                  Another driver is at the wheel · {@watchers} here
                <% true -> %>
                  No driver · {@watchers} here
              <% end %>
            </span>
            <%= if @am_driver and @project.status == "open" do %>
              <button class="btn btn-quiet" phx-click="release_driver">Hand over</button>
            <% end %>
            <%= if not @am_driver and @driver_id == nil and @project.status == "open" do %>
              <button class="btn btn-quiet" phx-click="claim_driver">Take the wheel</button>
            <% end %>
            <%= if @project.status == "open" do %>
              <button class="btn btn-gold" phx-click="commit" disabled={not @am_driver}>Commit</button>
            <% end %>
          </div>
        </header>

        <%= if @commit_arm do %>
          <div class="confirm-bar">
            <span>
              Commit locks this Project read-only and freezes the deliverable at the current revision. The implementing agent can still append to Decided-for-you.
            </span>
            <button class="btn btn-gold" phx-click="commit_confirm">Confirm commit</button>
            <button class="btn btn-quiet" phx-click="commit_cancel">Keep designing</button>
          </div>
        <% end %>

        <div class="layout">
          <nav class={"nav" <> if(@nav_open, do: " nav-open", else: "")}>
            <p class="eyebrow">Model</p>
            <%= if @model_text do %>
              <button class="nav-item" phx-click="open_file" phx-value-path="model.md">
                model.md <span class="nav-meta">the decision model</span>
              </button>
            <% else %>
              <p class="nav-empty">No model yet — it forms as you answer.</p>
            <% end %>

            <p class="eyebrow">Files</p>
            <%= for f <- @files, f.path != "model.md" do %>
              <button class="nav-item" phx-click="open_file" phx-value-path={f.path}>
                {f.path} <span class="nav-meta">v{f.version}</span>
              </button>
            <% end %>
            <%= if @files == [] do %>
              <p class="nav-empty">Files appear here as the design takes shape.</p>
            <% end %>

            <p class="eyebrow">Artifacts</p>
            <%= for name <- artifacts(@entries) do %>
              <button class="nav-item" phx-click="open_artifact" phx-value-name={name}>
                {name}.html <span class="nav-meta">open in pane</span>
              </button>
            <% end %>
            <%= if artifacts(@entries) == [] do %>
              <p class="nav-empty">No artifact yet.</p>
            <% end %>
            <button class="nav-item" phx-click="open_snapshot">
              + Add a page snapshot <span class="nav-meta">enters as version 0</span>
            </button>

            <p class="eyebrow">Explorer</p>
            <button class="nav-item" phx-click="open_explorer">
              File explorer <span class="nav-meta">exactly what gets exported</span>
            </button>
            <a class="nav-item nav-link" href="/export" download>
              Export bundle <span class="nav-meta">.zip — latest + history</span>
            </a>

            <p class="eyebrow">Standing</p>
            <p class="nav-standing">
              Predictions: {@tally.hits} hit · {@tally.misses} missed<br />
              Open questions: {@tally.open} · skipped {@tally.skipped} · out of scope {@tally.struck}
            </p>
            <%= if decisions(@entries) != [] do %>
              <p class="eyebrow">Decided for you</p>
              <%= for d <- decisions(@entries) do %>
                <p class="nav-decision">{d.body}</p>
              <% end %>
            <% end %>
          </nav>

          <main class="chat-col">
            <div class="chat" id="chat-stream">
              <%= for entry <- @entries do %>
                {render_entry(assigns, entry)}
              <% end %>

              <%= if @sharp and @project.status == "open" do %>
                <div class="sharp-banner">
                  <p><strong>The model reads sharp.</strong> Commit when you are ready — or keep asking.</p>
                  <%= if @am_driver do %>
                    <button class="btn btn-quiet" phx-click="keep_asking">Keep asking</button>
                  <% end %>
                </div>
              <% end %>

              <%= if @driver_status.state == :thinking do %>
                <p class="thinking">Thinking…</p>
              <% end %>
              <%= if @driver_status.state == :failed do %>
                <p class="driver-error">
                  The AI driver hit a problem and could not answer. Everything you have said is saved — send a message to retry, or keep working: the record, files and questions all still work.
                </p>
              <% end %>
            </div>

            <%= if @project.status == "open" do %>
              <form phx-submit="send_message" class="composer" id="composer" phx-hook="Composer">
                <%= if @chips != [] do %>
                  <div class="chips">
                    <%= for {chip, idx} <- Enum.with_index(@chips) do %>
                      <span class="chip chip-element" title={chip["path"]}>
                        ⌗ {chip_label(chip)} — {chip["text"]}
                        <button type="button" phx-click="remove_chip" phx-value-idx={idx} aria-label="Remove attachment">×</button>
                      </span>
                    <% end %>
                  </div>
                <% end %>
                <textarea
                  id="composer-box"
                  name="message[text]"
                  rows="2"
                  phx-hook="AutoResize"
                  placeholder={if @am_driver, do: "Message, answer in chat, or say “out of scope”…", else: "Take the wheel to write…"}
                  disabled={not @am_driver}
                  class="composer-box"
                ></textarea>
                <button type="submit" class="btn btn-gold" disabled={not @am_driver}>Send</button>
              </form>
            <% else %>
              <p class="committed-note">
                This Project is committed (read-only). To continue the line of thought, start a new Project.
              </p>
            <% end %>
          </main>

          <%= if @pane do %>
            <aside class="pane">
              <button class="icon-btn pane-close" phx-click="close_pane" aria-label="Close pane">×</button>
              {render_pane(assigns)}
            </aside>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp render_entry(assigns, %DesignSprite.Resources.Entry{kind: "want", body: body}) do
    assigns = assign(assigns, :body, body)

    ~H"""
    <div class="entry entry-want">
      <p class="eyebrow">The want</p>
      <div class="entry-body">{md(@body)}</div>
    </div>
    """
  end

  defp render_entry(assigns, %DesignSprite.Resources.Entry{kind: "message", actor: actor, body: body, payload: payload}) do
    elements = (payload && payload["elements"]) || []
    assigns = assigns |> assign(:body, body) |> assign(:actor, actor) |> assign(:elements, elements)

    ~H"""
    <div class={"entry entry-msg entry-msg-" <> @actor}>
      <p class="eyebrow">{if @actor == "ai", do: "Designer", else: "Driver"}</p>
      <div class="entry-body">{md(@body)}</div>
      <%= if @elements != [] do %>
        <div class="chips">
          <%= for el <- @elements do %>
            <span class="chip chip-element" title={el["path"]}>⌗ {chip_label(el)} — {el["text"]}</span>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_entry(assigns, %DesignSprite.Resources.Entry{kind: "question", payload: payload}) do
    view = Enum.find(assigns.views, &(&1.key == payload["key"]))

    if view do
      assigns = assign(assigns, :view, view)
      render_question_card(assigns)
    else
      Phoenix.HTML.raw("")
    end
  end

  defp render_entry(assigns, %DesignSprite.Resources.Entry{kind: "model", payload: p}) do
    assigns = assign(assigns, :version, p["version"])

    ~H"""
    <p class="entry-note">Model updated — v{@version}. <button class="link-btn" phx-click="open_file" phx-value-path="model.md">Read it</button></p>
    """
  end

  defp render_entry(assigns, %DesignSprite.Resources.Entry{kind: "artifact", payload: p}) do
    assigns = assigns |> assign(:name, p["name"]) |> assign(:version, p["version"]) |> assign(:payload, p)

    ~H"""
    <p class="entry-note">
      <%= cond do %>
        <% @payload["snapshot"] -> %>
          Snapshot {@name} — entered as v0.
        <% @payload["patch"] -> %>
          Artifact {@name} — patched to v{@version}{if @payload["element"], do: " (" <> @payload["element"] <> ")", else: ""}.
        <% true -> %>
          Artifact {@name} — v{@version}.
      <% end %>
      <button class="link-btn" phx-click="open_artifact" phx-value-name={@name}>Open it</button>
    </p>
    """
  end

  defp render_entry(assigns, %DesignSprite.Resources.Entry{kind: "decision", body: body}) do
    assigns = assign(assigns, :body, body)

    ~H"""
    <div class="entry entry-decision">
      <p class="eyebrow">Decided for you</p>
      <div class="entry-body">{md(@body)}</div>
    </div>
    """
  end

  defp render_entry(_assigns, %DesignSprite.Resources.Entry{kind: "system", payload: p}) do
    case p["event"] do
      "committed" ->
        Phoenix.HTML.raw(~s|<p class="entry-note">Project committed — the deliverable is frozen.</p>|)

      _ ->
        Phoenix.HTML.raw("")
    end
  end

  defp render_entry(_assigns, _entry), do: Phoenix.HTML.raw("")

  defp render_question_card(assigns) do
    view = assigns.view
    chip = score_chip(view)
    assigns = assigns |> assign(:view, view) |> assign(:chip, chip)

    ~H"""
    <div class={"qcard qcard-" <> to_string(@view.state)}>
      <p class="eyebrow">Question{if @view.question["axis"], do: " · " <> @view.question["axis"], else: ""}</p>
      <p class="qcard-prompt">{@view.question["prompt"]}</p>
      <%= if @view.question["context"] do %>
        <p class="qcard-context">{@view.question["context"]}</p>
      <% end %>
      <%= case @view.state do %>
        <% :open -> %>
          <button class="btn btn-quiet" phx-click="open_question" phx-value-key={@view.key}>Answer</button>
          <span class="qcard-hint">{length(@view.question["options"])} options · prediction made</span>
        <% :skipped -> %>
          <p class="qcard-state">Skipped — the prediction stands. <button class="link-btn" phx-click="open_question" phx-value-key={@view.key}>Answer it after all</button></p>
        <% :struck -> %>
          <p class="qcard-state">Out of scope — this axis is off the map.</p>
        <% :answered -> %>
          <p class="qcard-answer">{answer_summary(@view)}</p>
          <%= if @view.answer["comment"] not in [nil, ""] do %>
            <p class="qcard-comment">“{@view.answer["comment"]}”</p>
          <% end %>
          <%= if @chip do %>
            <span class={@chip.class}>{@chip.text}{if @chip.provisional, do: " (comment pending review)", else: ""}</span>
          <% end %>
          <%= if @project.status == "open" do %>
            <button class="link-btn" phx-click="open_question" phx-value-key={@view.key}>Change answer</button>
          <% end %>
      <% end %>
    </div>
    """
  end

  defp render_pane(assigns) do
    case assigns.pane do
      {:question, _key} ->
        case pane_question(assigns) do
          nil -> ~H|<p class="pane-empty">That question is gone.</p>|
          view -> pane_question_render(assigns, view)
        end

      {:artifact, name, ver} ->
        versions = DesignSprite.Artifacts.version_numbers(name)
        latest = DesignSprite.Artifacts.current_version(name)
        viewing = if ver == :latest, do: latest, else: ver

        src =
          if viewing == latest,
            do: "/artifact/" <> name,
            else: "/artifact/" <> name <> "/v/" <> Integer.to_string(viewing || 0)

        assigns =
          assigns
          |> assign(:name, name)
          |> assign(:versions, versions)
          |> assign(:latest, latest)
          |> assign(:viewing, viewing)
          |> assign(:src, src)

        ~H"""
        <p class="eyebrow">Artifact</p>
        <h2 class="pane-title">{@name}.html</h2>
        <div class="version-row">
          <%= for v <- @versions do %>
            <button
              class={"version-chip" <> if(v == @viewing, do: " version-current", else: "")}
              phx-click="open_artifact_version"
              phx-value-name={@name}
              phx-value-version={v}
            >
              v{v}{if v == @latest, do: " · latest", else: ""}{if v == 0, do: " · snapshot", else: ""}
            </button>
          <% end %>
        </div>
        <%= if @viewing != @latest do %>
          <p class="pane-note">Viewing v{@viewing} — history is kept, but feedback patches the latest (v{@latest}).</p>
        <% else %>
          <p class="pane-note">Click an element to attach it to your next chat message — feedback patches this into a new version.</p>
        <% end %>
        <iframe src={@src} class="artifact-frame" sandbox="allow-scripts"></iframe>
        """

      :snapshot ->
        ~H"""
        <p class="eyebrow">Artifact</p>
        <h2 class="pane-title">Add a page snapshot</h2>
        <p class="pane-note">
          An existing page enters as version 0: paste its HTML and it becomes an artifact the interview can point at and patch, like any generated one.
        </p>
        <form phx-submit="add_snapshot" class="snapshot-form">
          <label class="comment-label" for="snapshot-name">Name</label>
          <input type="text" id="snapshot-name" name="snapshot[name]" placeholder="e.g. current-pricing-page" />
          <label class="comment-label" for="snapshot-html">Page HTML</label>
          <textarea id="snapshot-html" name="snapshot[html]" rows="10" class="snapshot-html" placeholder="<!doctype html>…"></textarea>
          <button type="submit" class="btn btn-gold" disabled={not @am_driver}>Add snapshot as v0</button>
        </form>
        """

      :explorer ->
        files = DesignSprite.Export.exportable_files()
        assigns = assign(assigns, :export_files, files)

        ~H"""
        <p class="eyebrow">File explorer</p>
        <h2 class="pane-title">What gets exported</h2>
        <p class="pane-note">
          This is the whole exportable set — the same files the bundle and the API hand to an implementing agent. Latest revision first; every version is kept.
        </p>
        <p class="explorer-bundle">
          <a class="btn btn-gold" href="/export" download>Download the export bundle (.zip)</a>
        </p>
        <div class="explorer-list">
          <%= for f <- @export_files do %>
            <div class="explorer-row">
              <div class="explorer-main">
                <span class="explorer-path">{f.path}</span>
                <span class="explorer-meta">
                  <%= if f.kind == "projection" do %>
                    live projection of the record
                  <% else %>
                    v{f.version} · {f.versions} version{if f.versions != 1, do: "s", else: ""} · {f.bytes} bytes
                  <% end %>
                </span>
              </div>
              <button class="btn btn-quiet" phx-click="open_file" phx-value-path={f.path}>View</button>
              <a class="btn btn-quiet" href={"/files/raw?path=" <> URI.encode_www_form(f.path)} download>Download</a>
            </div>
          <% end %>
        </div>
        """

      {:file, path, ver} ->
        projection = DesignSprite.Export.projection?(path)

        versions =
          if projection do
            []
          else
            path |> ProjectFiles.versions() |> Enum.map(& &1.version) |> Enum.sort()
          end

        viewing = if ver == :latest, do: List.last(versions), else: ver

        content =
          case DesignSprite.Export.read(path, ver) do
            {:ok, text} -> text
            _ -> nil
          end

        download =
          "/files/raw?path=" <> URI.encode_www_form(path) <>
            if(ver == :latest, do: "", else: "&version=#{ver}")

        assigns =
          assigns
          |> assign(:path, path)
          |> assign(:content, content)
          |> assign(:versions, versions)
          |> assign(:viewing, viewing)
          |> assign(:projection, projection)
          |> assign(:download, download)

        ~H"""
        <p class="eyebrow">File</p>
        <h2 class="pane-title">{@path}</h2>
        <%= if @projection do %>
          <p class="pane-note">A live projection of the record, regenerated on every read — the record itself is its history.</p>
        <% else %>
          <div class="version-row">
            <%= for v <- @versions do %>
              <button
                class={"version-chip" <> if(v == @viewing, do: " version-current", else: "")}
                phx-click="open_file_version"
                phx-value-path={@path}
                phx-value-version={v}
              >
                v{v}{if v == List.last(@versions), do: " · latest", else: ""}{if v == 0, do: " · snapshot", else: ""}
              </button>
            <% end %>
          </div>
          <%= if @viewing != List.last(@versions) do %>
            <p class="pane-note">Viewing v{@viewing} — history is kept; the latest revision is what the deliverable carries.</p>
          <% end %>
        <% end %>
        <p class="explorer-bundle">
          <a class="link-btn" href={@download} download>Download {if @viewing && not @projection, do: "v" <> Integer.to_string(@viewing), else: "this file"}</a>
        </p>
        <%= if @content do %>
          <%= if String.ends_with?(@path, ".md") do %>
            <div class="file-body">{md(@content)}</div>
          <% else %>
            <pre class="file-body file-pre">{@content}</pre>
          <% end %>
        <% else %>
          <p class="pane-empty">No such file.</p>
        <% end %>
        """
    end
  end

  defp pane_question_render(assigns, view) do
    draft = effective_draft(view, assigns.drafts[view.key] || %{})
    assigns = assigns |> assign(:view, view) |> assign(:draft, draft)

    ~H"""
    <p class="eyebrow">Question{if @view.question["axis"], do: " · " <> @view.question["axis"], else: ""}</p>
    <h2 class="pane-title">{@view.question["prompt"]}</h2>
    <%= if @view.question["context"] do %>
      <p class="pane-note">{@view.question["context"]}</p>
    <% end %>

    <%= if @view.state == :answered do %>
      <p class="qcard-answer">{answer_summary(@view)}</p>
      <%= if @view.answer["comment"] not in [nil, ""] do %>
        <p class="qcard-comment">“{@view.answer["comment"]}”</p>
      <% end %>
      <%= if @project.status == "open" do %>
        <p class="pane-note">
          Change your answer below — the change is appended as a superseding answer; the original stays in the record as history and only the latest counts.
        </p>
      <% end %>
    <% end %>
    <%= if @view.state == :struck do %>
      <p class="pane-note">Out of scope — this axis is off the map.</p>
    <% else %>
      <%= if not (@view.state == :answered and @project.status != "open") do %>
        <form phx-change="draft_answer" phx-submit="send_answer" class="answer-form" id={"answer-form-" <> @view.key} phx-hook="DraftFlush">
          <input type="hidden" name="answer[question_key]" value={@view.key} />
          <%= case @view.question["type"] do %>
            <% "single" -> %>
              <div class="options">
                <%= for o <- @view.question["options"] do %>
                  <button
                    type="button"
                    class="option-row"
                    phx-click="answer_option"
                    phx-value-key={@view.key}
                    phx-value-choice={o["value"]}
                    disabled={not @am_driver}
                  >
                    {o["label"]}
                  </button>
                <% end %>
                <div class="option-other">
                  <label>
                    <input type="radio" name="answer[choice]" value="other" checked={@draft["choice"] == "other"} /> Other
                  </label>
                  <input type="text" name="answer[other_text]" value={@draft["other_text"]} placeholder="Your answer…" />
                  <button type="submit" class="btn btn-quiet" disabled={not @am_driver}>{if @view.state == :answered, do: "Save changed answer", else: "Send answer"}</button>
                </div>
              </div>
            <% "preview" -> %>
              <% stops = numeric_stops(@view.question) %>
              <div class="variant-matrix">
                <%= for o <- @view.question["options"] do %>
                  <label class={"variant" <> if(@draft["choice"] == o["value"], do: " variant-selected", else: "")}>
                    <span class="variant-head">
                      <input type="radio" name="answer[choice]" value={o["value"]} checked={@draft["choice"] == o["value"]} />
                      <span class="option-label">{o["label"]}</span>
                    </span>
                    <%= if o["preview"] do %>
                      <span class="variant-frame"><iframe srcdoc={o["preview"]} sandbox="" title={o["label"]}></iframe></span>
                    <% end %>
                  </label>
                <% end %>
                <label class="variant">
                  <span class="variant-head">
                    <input type="radio" name="answer[choice]" value="other" checked={@draft["choice"] == "other"} />
                    <span class="option-label">Other</span>
                  </span>
                </label>
              </div>
              <input type="text" name="answer[other_text]" value={@draft["other_text"]} placeholder="Your answer, if Other…" />
              <%!-- The dial renders ONLY when the question actually has dial stops
                   (every option value numeric). A preview question without dial
                   stops gets no dial input at all. --%>
              <%= if stops do %>
                <div class="dial">
                  <label class="comment-label" for={"dial-" <> @view.key}>
                    Dial <span class="comment-hint">(the dialed value is the answer, recorded verbatim)</span>
                  </label>
                  <input
                    type="range"
                    id={"dial-" <> @view.key}
                    min={elem(hd(stops), 1)}
                    max={elem(List.last(stops), 1)}
                    step={dial_step(stops)}
                    value={dial_initial(@view.question, @draft, stops)}
                    phx-hook="Dial"
                  />
                  <input
                    type="text"
                    name="answer[dialed_value]"
                    value={@draft["dialed_value"]}
                    placeholder="Dialed value…"
                    aria-label="Dialed value"
                  />
                </div>
              <% end %>
              <button type="submit" class="btn btn-gold" disabled={not @am_driver}>{if @view.state == :answered, do: "Save changed answer", else: "Send answer"}</button>
            <% "multi" -> %>
              <div class="options">
                <%= for o <- @view.question["options"] do %>
                  <label class="option-row">
                    <input
                      type="checkbox"
                      name="answer[choices][]"
                      value={o["value"]}
                      checked={o["value"] in (@draft["choices"] || [])}
                    />
                    <span class="option-label">{o["label"]}</span>
                  </label>
                <% end %>
                <label class="option-row">
                  <input type="checkbox" name="answer[choices][]" value="other" checked={"other" in (@draft["choices"] || [])} />
                  <span class="option-label">Other</span>
                </label>
                <input type="text" name="answer[other_text]" value={@draft["other_text"]} placeholder="Your answer, if Other…" />
              </div>
              <button type="submit" class="btn btn-gold" disabled={not @am_driver}>{if @view.state == :answered, do: "Save changed answer", else: "Send answer"}</button>
          <% end %>

          <label class="comment-label" for="answer-comment">Comment <span class="comment-hint">(part of the answer)</span></label>
          <textarea
            id="answer-comment"
            name="answer[comment]"
            rows="2"
            phx-hook="AutoResize"
            phx-debounce="300"
            placeholder="a, but…"
          >{@draft["comment"]}</textarea>
        </form>

        <%= if @view.state != :answered do %>
          <div class="pane-actions">
            <button class="link-btn" phx-click="skip_question" phx-value-key={@view.key} disabled={not @am_driver}>
              Skip — the prediction stands
            </button>
            <button class="link-btn link-danger" phx-click="strike_question" phx-value-key={@view.key} disabled={not @am_driver}>
              {if @strike_arm == @view.key, do: "Sure? Strike this axis for good", else: "Out of scope"}
            </button>
          </div>
        <% end %>
      <% end %>
    <% end %>
    """
  end
end
