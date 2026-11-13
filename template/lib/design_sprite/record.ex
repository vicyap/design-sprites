defmodule DesignSprite.Record do
  @moduledoc """
  The record: every read and every command over the append-only entry
  log. Writes funnel through DesignSprite.RecordWriter (single writer,
  monotonic seq). Nothing here updates or deletes an entry — a
  correction is a new entry (a superseding score, a strike, a later
  message).

  Question state is DERIVED from the log, never stored: a question is
  open until an answer lands; a skip leaves the prediction standing
  (and the question may still be answered later); a strike ("out of
  scope") removes the axis and is terminal for that question.
  """

  require Ash.Query

  alias DesignSprite.Resources.{Draft, Entry, Project}
  alias DesignSprite.RecordWriter

  # Entry kinds frozen once the Project is Committed. "decision"
  # (Decided-for-you) and "system" stay appendable after Commit.
  @post_commit_kinds ~w(decision system)

  def now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace_suffix("Z", "+00:00")
  end

  # ----------------------------------------------------------------
  # Project

  def project do
    case Project |> Ash.Query.sort(:id) |> Ash.Query.limit(1) |> Ash.read_one() do
      {:ok, project} -> project
      _ -> nil
    end
  end

  def committed? do
    match?(%Project{status: "committed"}, project())
  end

  @doc "Create the Project from the opening text box + append the want."
  def create_project(want) when is_binary(want) do
    want = String.trim(want)

    cond do
      want == "" ->
        {:error, :empty_want}

      project() != nil ->
        {:error, :project_exists}

      true ->
        params = %{want: want, status: "open", created_at: now_iso()}

        with {:ok, proj} <-
               Project |> Ash.Changeset.for_create(:create, params) |> Ash.create(),
             {:ok, _entry} <- append("want", "human", want, %{}) do
          {:ok, proj}
        end
    end
  end

  @doc "The deliberate human Commit press. One-way."
  def commit(actor) when actor in ["human", "agent"] do
    case project() do
      nil -> {:error, :no_project}
      %Project{status: "committed"} -> {:error, :already_committed}
      %Project{} = proj ->
        with {:ok, proj} <-
               proj
               |> Ash.Changeset.for_update(:update, %{
                 status: "committed",
                 committed_at: now_iso()
               })
               |> Ash.update(),
             {:ok, _} <- append("system", "system", nil, %{"event" => "committed"}) do
          DesignSprite.Observe.emit("project.commit", "succeeded", %{})
          DesignSprite.Webhook.commit(proj)
          {:ok, proj}
        end
    end
  end

  # ----------------------------------------------------------------
  # Appends

  @doc """
  Append an entry. Enforces the Commit freeze: after Commit only
  decision/system entries land; everything else gets
  {:error, :committed}.
  """
  def append(kind, actor, body \\ nil, payload \\ nil) do
    if committed?() and kind not in @post_commit_kinds do
      {:error, :committed}
    else
      RecordWriter.append(%{kind: kind, actor: actor, body: body, payload: payload})
    end
  end

  @doc "A chat message (human from the web, agent via API, ai from the driver)."
  def post_message(actor, text, elements \\ [])
      when actor in ["human", "agent", "ai"] and is_binary(text) do
    payload = if elements == [], do: %{}, else: %{"elements" => elements}
    append("message", actor, text, payload)
  end

  @doc "A Decided-for-you entry — appendable even after Commit."
  def append_decision(actor, text) when actor in ["human", "agent", "ai"] do
    append("decision", actor, text, %{})
  end

  @doc "Record an artifact version in the stream (the file write already happened)."
  def append_artifact_entry(name, version, actor, extra \\ %{}) do
    payload =
      Map.merge(
        %{
          "name" => DesignSprite.Artifacts.sanitize_name(name),
          "path" => DesignSprite.Artifacts.path_for(name),
          "version" => version
        },
        extra
      )

    append("artifact", actor, nil, payload)
  end

  @doc """
  Enter an existing page as a snapshot artifact (version 0) and
  record it in the stream. The Commit freeze applies: snapshots are
  design content, so a committed Project refuses them.
  """
  def snapshot_artifact(name, html, actor) when actor in ["human", "agent"] do
    cond do
      committed?() ->
        {:error, :committed}

      DesignSprite.Artifacts.sanitize_name(name) in [nil, ""] ->
        {:error, :snapshot_name_required}

      not is_binary(html) or String.trim(html) == "" ->
        {:error, :snapshot_empty}

      true ->
        case DesignSprite.Artifacts.snapshot(name, html, actor) do
          {:ok, 0} -> append_artifact_entry(name, 0, actor, %{"snapshot" => true})
          {:error, _} = err -> err
        end
    end
  end

  @doc "Post a question card (the built-in AI or an external driver)."
  def post_question(actor, question) when actor in ["ai", "agent"] do
    case validate_question(question) do
      :ok -> append("question", actor, nil, question)
      {:error, _} = err -> err
    end
  end

  def validate_question(q) when is_map(q) do
    options = q["options"] || []
    values = Enum.map(options, & &1["value"])
    prediction = q["prediction"]

    cond do
      not is_binary(q["key"]) or q["key"] == "" ->
        {:error, :question_key_required}

      q["type"] not in ["single", "multi", "preview"] ->
        {:error, :question_type_invalid}

      q["load_bearing"] not in [nil, true, false] ->
        {:error, :question_load_bearing_invalid}

      not is_binary(q["prompt"]) or String.trim(q["prompt"]) == "" ->
        {:error, :question_prompt_required}

      q["type"] == "preview" and
          Enum.any?(options, fn o ->
            not is_binary(o["preview"]) or String.trim(o["preview"]) == ""
          end) ->
        {:error, :question_preview_required}

      length(options) < 2 or length(options) > 4 ->
        {:error, :question_options_count}

      length(values) != length(Enum.uniq(values)) ->
        {:error, :question_options_not_unique}

      Enum.any?(options, fn o -> not is_binary(o["label"]) or o["label"] == "" end) ->
        {:error, :question_option_label_required}

      prediction == nil ->
        {:error, :prediction_required}

      q["type"] in ["single", "preview"] and prediction not in values ->
        {:error, :prediction_not_an_option}

      q["type"] == "multi" and
          (not is_list(prediction) or prediction == [] or
             not Enum.all?(prediction, &(&1 in values))) ->
        {:error, :prediction_not_an_option}

      q["recommended"] not in [nil | values] and
          not (q["type"] == "multi" and is_list(q["recommended"]) and
                 Enum.all?(q["recommended"], &(&1 in values))) ->
        {:error, :recommended_not_an_option}

      true ->
        :ok
    end
  end

  def validate_question(_), do: {:error, :question_invalid}

  # ----------------------------------------------------------------
  # Answers, skips, strikes, scores

  @doc """
  Answer an open (or skipped) question. Appends the answer entry and,
  atomically in sequence, its deterministic score entry. The draft for
  the question is destroyed. Returns {:ok, %{answer: e, score: e}}.
  """
  def answer_question(key, attrs, actor) when actor in ["human", "agent"] do
    view = question_view(key)

    cond do
      view == nil ->
        {:error, :question_not_found}

      view.state == :struck ->
        {:error, :question_struck}

      view.state == :answered ->
        {:error, :already_answered}

      committed?() ->
        {:error, :committed}

      true ->
        attrs = normalize_answer_attrs(view.question, attrs)

        case validate_answer(view.question, attrs) do
          :ok ->
            payload = %{
              "question_key" => key,
              "choice" => attrs["choice"],
              "choices" => attrs["choices"],
              "other_text" => attrs["other_text"],
              "dialed_value" => dialed_value(view.question, attrs),
              "comment" => attrs["comment"]
            }

            with {:ok, answer} <- append("answer", actor, nil, payload),
                 {:ok, score} <- append_score(view.question, payload) do
              clear_draft(key)
              {:ok, %{answer: answer, score: score}}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  # A preview question may be answered by its dial instead of by a
  # form-shaped choice. Normalize only the routing fields here; the
  # dialed value itself is preserved byte-for-byte in the payload.
  # - a dialed stop that is one of the options becomes that choice;
  # - any other non-empty dialed value becomes the Other text.
  defp normalize_answer_attrs(%{"type" => "preview"} = question, attrs) do
    dialed = attrs["dialed_value"]
    choice = attrs["choice"]
    values = Enum.map(question["options"] || [], & &1["value"])

    cond do
      not is_binary(dialed) or dialed == "" ->
        attrs

      choice not in [nil, ""] ->
        attrs

      dialed in values ->
        Map.put(attrs, "choice", dialed)

      true ->
        attrs
        |> Map.put("choice", "other")
        |> Map.put("other_text", dialed)
    end
  end

  defp normalize_answer_attrs(_question, attrs), do: attrs

  defp dialed_value(%{"type" => "preview"}, attrs) do
    cond do
      is_binary(attrs["dialed_value"]) and attrs["dialed_value"] != "" ->
        attrs["dialed_value"]

      attrs["choice"] == "other" ->
        attrs["other_text"]

      true ->
        attrs["choice"]
    end
  end

  defp dialed_value(_question, _attrs), do: nil

  defp validate_answer(question, attrs) do
    values = Enum.map(question["options"], & &1["value"])
    comment = String.trim(attrs["comment"] || "")
    _ = comment

    case question["type"] do
      "multi" ->
        choices = attrs["choices"] || []

        cond do
          choices == [] -> {:error, :choice_required}
          not Enum.all?(choices, &(&1 in values or &1 == "other")) -> {:error, :choice_invalid}
          "other" in choices and String.trim(attrs["other_text"] || "") == "" -> {:error, :other_text_required}
          true -> :ok
        end

      _single_or_preview ->
        choice = attrs["choice"]
        dialed = attrs["dialed_value"]

        cond do
          question["type"] == "preview" and dialed not in [nil, ""] and
              not is_binary(dialed) ->
            {:error, :dialed_value_invalid}

          question["type"] == "preview" and is_binary(dialed) and dialed != "" and
              choice in values and dialed != choice ->
            {:error, :dialed_value_mismatch}

          question["type"] == "preview" and is_binary(dialed) and dialed != "" and
              choice == "other" and dialed != (attrs["other_text"] || "") ->
            {:error, :dialed_value_mismatch}

          choice == nil or choice == "" ->
            {:error, :choice_required}

          choice != "other" and choice not in values ->
            {:error, :choice_invalid}

          choice == "other" and String.trim(attrs["other_text"] || "") == "" ->
            {:error, :other_text_required}

          true ->
            :ok
        end
    end
  end

  @doc """
  The deterministic score for an answer (contract item 5):
  - Other (alone or in a multi set) is a miss.
  - An exact prediction match is a hit; anything else a miss.
  - A non-empty comment makes the score PROVISIONAL: the AI's next
    turn confirms it or appends a superseding miss if the comment
    changes the build. Skips get no score entry at all.
  """
  def score_answer(question, answer) do
    prediction = question["prediction"]
    comment? = String.trim(answer["comment"] || "") != ""

    {result, reason} =
      case question["type"] do
        "multi" ->
          choices = answer["choices"] || []

          cond do
            "other" in choices -> {"miss", "other"}
            Enum.sort(choices) == Enum.sort(List.wrap(prediction)) -> {"hit", "choice_match"}
            true -> {"miss", "choice"}
          end

        _ ->
          choice = answer["choice"]

          cond do
            choice == "other" -> {"miss", "other"}
            choice == prediction -> {"hit", "choice_match"}
            true -> {"miss", "choice"}
          end
      end

    %{"result" => result, "reason" => reason, "provisional" => comment?}
  end

  defp append_score(question, answer_payload) do
    score = score_answer(question, answer_payload)

    payload =
      Map.merge(score, %{
        "question_key" => question["key"],
        "source" => "deterministic"
      })

    append("score", "system", nil, payload)
  end

  @doc """
  Append a superseding score (the AI judging a provisional one, or an
  external driver doing the same). The latest score per question is
  the effective one.
  """
  def supersede_score(question_key, result, reason, actor)
      when result in ["hit", "miss"] and actor in ["ai", "agent"] do
    if question_view(question_key) == nil do
      {:error, :question_not_found}
    else
      append("score", actor, nil, %{
        "question_key" => question_key,
        "result" => result,
        "reason" => reason,
        "provisional" => false,
        "source" => "judged"
      })
    end
  end

  @doc """
  Keys of answered questions whose effective score is still
  provisional — a comment-carrying score the AI has not yet judged
  (D6). Derived from the record every time, so it is the truth the
  driver loop checks its turns against.
  """
  def provisional_question_keys do
    question_views()
    |> Enum.filter(
      &(&1.state == :answered and &1.score != nil and &1.score["provisional"] == true)
    )
    |> Enum.map(& &1.key)
  end

  @doc "Skip: the prediction stands, no score. The question may still be answered."
  def skip_question(key, actor, note \\ nil) when actor in ["human", "agent"] do
    case question_view(key) do
      nil -> {:error, :question_not_found}
      %{state: :answered} -> {:error, :already_answered}
      %{state: :struck} -> {:error, :question_struck}
      _ -> append("skip", actor, note, %{"question_key" => key})
    end
  end

  @doc "Strike: 'out of scope' — the axis is removed. Terminal for the question."
  def strike_question(key, actor, note \\ nil) when actor in ["human", "agent"] do
    case question_view(key) do
      nil -> {:error, :question_not_found}
      %{state: :answered} -> {:error, :already_answered}
      _ -> append("strike", actor, note, %{"question_key" => key})
    end
  end

  # ----------------------------------------------------------------
  # Sharpness

  @doc "The latest free-chat utterance from the human Driver, if any."
  def latest_human_message do
    entries()
    |> Enum.reverse()
    |> Enum.find(&(&1.kind == "message" and &1.actor == "human"))
  end

  @doc """
  Deterministic sharpness gate (contract item 9). The AI proposes
  sharpness; this gate decides whether the recent record can carry
  that declaration:

  - at least three answered load-bearing questions;
  - the three most recent load-bearing scores are all final
    (non-provisional) hits;
  - no load-bearing question is still open or skipped.

  Struck axes are excluded, and non-load-bearing questions neither
  supply the three hits nor block the declaration.
  """
  def sharpness_status do
    views = question_views()

    answered =
      Enum.filter(views, fn view ->
        view.state == :answered and view.score != nil and
          view.question["load_bearing"] != false
      end)

    recent = Enum.take(answered, -3)

    blocking =
      Enum.filter(views, fn view ->
        view.state in [:open, :skipped] and view.question["load_bearing"] != false
      end)

    recent_results = Enum.map(recent, & &1.score["result"])
    recent_provisional? = Enum.any?(recent, &(&1.score["provisional"] == true))

    eligible =
      length(recent) == 3 and recent_results == ["hit", "hit", "hit"] and
        not recent_provisional? and blocking == []

    %{
      eligible: eligible,
      answered_load_bearing: length(answered),
      recent_results: recent_results,
      recent_provisional: recent_provisional?,
      blocking_open_or_skipped: length(blocking)
    }
  end

  @doc "Whether the deterministic sharpness gate is currently satisfied."
  def sharpness_ready?, do: sharpness_status().eligible

  @doc "The AI declares the model sharp (contract item 9)."
  def declare_sharp(actor) when actor in ["ai", "agent"] do
    append("system", actor, nil, %{"event" => "sharp"})
  end

  @doc "The human says 'keep asking' — the frontier reopens."
  def resume do
    append("system", "human", nil, %{"event" => "resume"})
  end

  @doc "Derived: is the model currently declared sharp?"
  def sharp? do
    entries()
    |> Enum.filter(&(&1.kind == "system"))
    |> Enum.map(& &1.payload["event"])
    |> Enum.filter(&(&1 in ["sharp", "resume"]))
    |> List.last() == "sharp"
  end

  # ----------------------------------------------------------------
  # Reads

  def entries do
    Entry |> Ash.Query.sort(:seq) |> Ash.read!()
  end

  def entries_since(seq) do
    Entry
    |> Ash.Query.filter(seq > ^seq)
    |> Ash.Query.sort(:seq)
    |> Ash.read!()
  end

  @doc "All question views, in the order the questions were asked."
  def question_views do
    initial = %{}

    views =
      Enum.reduce(entries(), initial, fn entry, acc ->
        payload = entry.payload || %{}

        case entry.kind do
          "question" ->
            key = payload["key"]

            Map.put(acc, key, %{
              key: key,
              question: payload,
              state: :open,
              answer: nil,
              score: nil,
              asked_seq: entry.seq
            })

          "answer" ->
            update_view(acc, payload["question_key"], fn v ->
              %{v | state: :answered, answer: payload}
            end)

          "skip" ->
            update_view(acc, payload["question_key"], fn v ->
              if v.state == :open, do: %{v | state: :skipped}, else: v
            end)

          "strike" ->
            update_view(acc, payload["question_key"], fn v ->
              if v.state == :answered, do: v, else: %{v | state: :struck}
            end)

          "score" ->
            update_view(acc, payload["question_key"], fn v -> %{v | score: payload} end)

          _ ->
            acc
        end
      end)

    views
    |> Map.values()
    |> Enum.sort_by(& &1.asked_seq)
  end

  def question_view(key) do
    Enum.find(question_views(), &(&1.key == key))
  end

  defp update_view(acc, key, fun) do
    case Map.fetch(acc, key) do
      {:ok, view} -> Map.put(acc, key, fun.(view))
      :error -> acc
    end
  end

  @doc "Score tally over effective (latest) scores; skips and strikes excluded."
  def tally do
    views = question_views()

    %{
      hits: Enum.count(views, &(&1.score && &1.score["result"] == "hit")),
      misses: Enum.count(views, &(&1.score && &1.score["result"] == "miss")),
      answered: Enum.count(views, &(&1.state == :answered)),
      open: Enum.count(views, &(&1.state == :open)),
      skipped: Enum.count(views, &(&1.state == :skipped)),
      struck: Enum.count(views, &(&1.state == :struck))
    }
  end

  # ----------------------------------------------------------------
  # Drafts (mutable half-answers — NOT part of the record)

  def save_draft(key, payload) when is_map(payload) do
    Draft
    |> Ash.Changeset.for_create(:create, %{
      question_key: key,
      payload: payload,
      updated_at: now_iso()
    })
    |> Ash.create()
    |> case do
      {:ok, draft} -> {:ok, draft}
      {:error, _} = err -> err
    end
  end

  def draft(key) do
    case Draft |> Ash.Query.filter(question_key == ^key) |> Ash.read_one() do
      {:ok, draft} -> draft
      _ -> nil
    end
  end

  def drafts do
    Draft |> Ash.read!() |> Map.new(&{&1.question_key, &1.payload || %{}})
  end

  def clear_draft(key) do
    case draft(key) do
      nil -> :ok
      draft -> Ash.destroy!(draft); :ok
    end
  end

  # ----------------------------------------------------------------
  # Transcript (the AI context rebuild + the transcript.md projection)

  @doc """
  The whole record as plain text. This is both the transcript file's
  content and the AI driver's context: compaction = rebuild from the
  verbatim record, never a summary of it.
  """
  def transcript_text do
    lines =
      Enum.map(entries(), fn e ->
        header = "##{e.seq} [#{e.actor}/#{e.kind}] #{e.created_at}"
        body = render_entry_body(e)
        if body == "", do: header, else: header <> "\n" <> body
      end)

    (["# Project transcript (append-only record)"] ++ lines) |> Enum.join("\n\n")
  end

  defp render_entry_body(%Entry{kind: "question", payload: p}) do
    options =
      (p["options"] || [])
      |> Enum.map(fn o -> "  - #{o["value"]}: #{o["label"]}" end)
      |> Enum.join("\n")

    """
    Q(#{p["key"]}, #{p["type"]}): #{p["prompt"]}
    #{if p["context"], do: "context: #{p["context"]}\n", else: ""}#{options}
      prediction: #{inspect(p["prediction"])}#{if p["recommended"], do: " recommended: #{inspect(p["recommended"])}", else: ""}
    """
    |> String.trim_trailing()
  end

  defp render_entry_body(%Entry{kind: "answer", payload: p}) do
    dialed = p["dialed_value"]

    parts =
      [
        {"choice", if(dialed in [nil, ""], do: p["choice"])},
        {"choices", p["choices"] && inspect(p["choices"])},
        {"dialed", dialed},
        {"other", if(dialed in [nil, ""], do: p["other_text"])},
        {"comment", p["comment"]}
      ]
      |> Enum.reject(fn {_k, v} -> v == nil or v == "" end)
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)

    "A(#{p["question_key"]}): " <> Enum.join(parts, " | ")
  end

  defp render_entry_body(%Entry{kind: "score", payload: p}) do
    "score(#{p["question_key"]}): #{p["result"]} (#{p["reason"]}#{if p["provisional"], do: ", provisional", else: ""})"
  end

  defp render_entry_body(%Entry{kind: kind, payload: p, body: body})
       when kind in ["skip", "strike"] do
    "#{kind}(#{p["question_key"]})#{if body, do: ": #{body}", else: ""}"
  end

  # A chat message may carry inspector attachments (elements the
  # Driver clicked in the artifact). They are part of what the
  # message MEANS, so the verbatim rebuild shows them: the AI's
  # patch targets these elements.
  defp render_entry_body(%Entry{kind: "message", payload: p, body: body}) do
    elements = (p && p["elements"]) || []

    attachments =
      Enum.map(elements, fn el ->
        id = el["id"]
        label = if id not in [nil, ""], do: "#{el["tag"]}##{id}", else: "#{el["tag"]} (#{el["path"]})"
        "  attached: #{label} — \"#{el["text"]}\" [artifact: #{el["artifact"]}]"
      end)

    ([body || ""] ++ attachments) |> Enum.join("\n") |> String.trim_trailing()
  end

  defp render_entry_body(%Entry{body: body}), do: body || ""
end
