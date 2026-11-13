defmodule DesignSprite.AI.Driver do
  @moduledoc """
  The built-in AI driver loop. Human-side events (the want, a message,
  an answer, a skip, a strike) kick this process; each kick runs at
  most one model turn at a time (kicks during a turn coalesce into
  one follow-up turn). A turn:

  1. rebuilds context from the verbatim record (never a summary),
  2. calls the model through the AI adapter,
  3. validates the whole reply, then applies it: AI messages, question
     cards, the artifact file, the re-derived model.md, sharpness,
  4. checks the applied turn against the RECORD for defects — an
     unjudged provisional score (F1), an announced question that
     never landed (F2), an artifact refused for missing ids (F4) —
     and makes one correction call inside the turn to close them.
     Defects that survive are reported as a degraded turn, in the
     turn result and in Observe, never silently accepted.

  Failure posture (contract item 11): a failed turn changes nothing in
  the record; the failure shows up in Observe and in the UI via the
  driver status broadcast — never a silent stall. A turn also has a
  hard time cap: if the model call hangs past it, the turn is killed
  and reported as failed rather than leaving the Project "thinking"
  forever. The Project stays fully usable as a record while the
  driver is down.
  """

  use GenServer

  alias DesignSprite.{Observe, ProjectFiles, Record}
  alias DesignSprite.AI.{Client, Prompt}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Ask the driver to take a turn (async, coalescing)."
  def kick do
    GenServer.cast(__MODULE__, :kick)
    :ok
  end

  @doc "Current driver status: %{state: :idle|:thinking|:failed, last_error: term}."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ----------------------------------------------------------------

  # Hard cap on one turn. Contract 11 forbids a silent stall, so the
  # driver kills an over-long turn and surfaces it as a visible
  # failure; the record is untouched either way because a turn
  # applies only after a full reply arrives. The cap is a STALL
  # bound, not a latency budget, and is sized from measurement
  # (2026-11-12 turn-timeout diagnosis, STATUS.md): the model's
  # adaptive thinking makes a healthy turn slow, and its
  # deliberation sometimes burns a whole call — the gateway client
  # answers that with up to four visible attempts per logical call
  # (spaced to decorrelate the draws), each bounded by the stream
  # IDLE timeout (silence between chunks, ~120s — the real stall
  # detector, one layer down). A turn is two logical calls (primary
  # + at most one correction); this cap sits above the honest
  # primary worst case (~4 × ~130s + pauses ≈ 10 min) as the
  # last-resort bound only — a turn it kills has still applied
  # whatever its primary call landed, and every attempt boundary
  # is visible in ai.call lines. Typical turns land in 1–5 minutes.
  # The original 150s cap predated the diagnosis: it sat inside the
  # healthy envelope and reported slow turns as failures.
  defp turn_timeout_ms do
    Application.get_env(:design_sprite, :driver_turn_timeout_ms, 900_000)
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       busy: false,
       pending: false,
       state: :idle,
       last_error: nil,
       current: nil,
       turn_started_ms: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{state: state.state, last_error: state.last_error}, state}
  end

  @impl true
  def handle_cast(:kick, state) do
    cond do
      Record.project() == nil -> {:noreply, state}
      Record.committed?() -> {:noreply, state}
      state.busy -> {:noreply, %{state | pending: true}}
      true -> {:noreply, start_turn(state)}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    if current?(state, ref) do
      Process.demonitor(ref, [:flush])
      state = finish_turn(state, result)

      if state.pending do
        {:noreply, start_turn(%{state | pending: false})}
      else
        {:noreply, state}
      end
    else
      # A late reply from a turn that already timed out: the turn
      # was declared failed and nothing it returns may land now.
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if current?(state, ref) do
      state = finish_turn(state, {:error, {:task_exit, reason}})
      {:noreply, %{state | pending: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:turn_timeout, ref}, state) do
    if current?(state, ref) and state.busy do
      {_ref, pid} = state.current
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])
      state = finish_turn(state, {:error, :turn_timeout})

      if state.pending do
        {:noreply, start_turn(%{state | pending: false})}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp current?(%{current: {ref, _pid}}, ref), do: true
  defp current?(_state, _ref), do: false

  defp start_turn(state) do
    task = Task.Supervisor.async_nolink(DesignSprite.TaskSupervisor, fn -> run_turn() end)
    Process.send_after(self(), {:turn_timeout, task.ref}, turn_timeout_ms())
    broadcast_status(:thinking, nil)

    %{
      state
      | busy: true,
        state: :thinking,
        last_error: nil,
        current: {task.ref, task.pid},
        turn_started_ms: System.monotonic_time(:millisecond)
    }
  end

  defp finish_turn(state, result) do
    duration_ms =
      case state.turn_started_ms do
        started when is_integer(started) -> System.monotonic_time(:millisecond) - started
        _ -> nil
      end

    state = %{state | current: nil, turn_started_ms: nil}

    case result do
      {:ok, applied} ->
        # Sharpness stands only while the AI keeps standing by it:
        # a turn that engages new input without re-declaring sharp
        # quietly reopens the frontier.
        if Record.sharp?() and not applied.sharp do
          Record.append("system", "system", nil, %{"event" => "resume"})
        end

        broadcast_status(:idle, nil)
        %{state | busy: false, state: :idle, last_error: nil}

      {:error, reason} ->
        fields = DesignSprite.AI.ErrorInfo.fields(reason)
        fields = if duration_ms, do: Map.put(fields, "duration_ms", duration_ms), else: fields
        Observe.emit("ai.turn", "failed", fields)
        broadcast_status(:failed, reason)
        %{state | busy: false, state: :failed, last_error: reason}
    end
  end

  defp broadcast_status(state, error) do
    Phoenix.PubSub.broadcast(
      DesignSprite.PubSub,
      "project",
      {:driver_status, %{state: state, last_error: error}}
    )
  end

  # ----------------------------------------------------------------
  # The turn itself (runs in a task)

  def run_turn do
    started = System.monotonic_time(:millisecond)
    system = Prompt.system_prompt()
    trigger = Record.latest_human_message()
    pending = Record.provisional_question_keys()
    start_versions = artifact_versions()

    with {:ok, reply} <- Client.generate(system, Prompt.build_context(), reply_schema()),
         {:ok, applied} <- apply_reply(reply, trigger) do
      defects = turn_defects(defect_view(applied, reply), pending, start_versions)
      {applied, defects} = correct_turn(applied, defects, pending, start_versions, system, trigger)

      applied =
        Map.merge(applied, %{
          unresolved_provisional: defects.unresolved_provisional,
          question_mismatch: defects.question_mismatch,
          degraded: defects?(defects)
        })

      # A turn that lands everything it owed is "succeeded"; a turn
      # that still owes the record something after its one correction
      # is "degraded" — visible in the turn's own outcome, never a
      # silent shortfall buried in a count (pilot findings F1/F2/F4).
      Observe.emit("ai.turn", if(applied.degraded, do: "degraded", else: "succeeded"), %{
        duration_ms: System.monotonic_time(:millisecond) - started,
        messages: length(applied.messages),
        questions: length(applied.questions),
        actions: length(applied.actions),
        score_judgements: length(applied.score_judgements),
        patches: length(applied.patches),
        questions_dropped: applied.questions_dropped,
        artifacts_rejected: applied.artifacts_rejected,
        unresolved_provisional: length(applied.unresolved_provisional),
        question_mismatch: if(defects.question_mismatch, do: 1, else: 0)
      })

      {:ok, applied}
    end
  end

  # ----------------------------------------------------------------
  # Turn defects + the one in-turn correction (F1/F2/F4)
  #
  # A reply can land and still leave the record short of what it
  # owed or announced:
  # - F1: a provisional (comment-carrying) score pending at the
  #   turn's start was not judged — prose claiming "the hit stands"
  #   is not a judgement; only the structured entry is.
  # - F2: the reply's declared question count disagrees with the
  #   questions array (an announced question was never asked), or a
  #   question object was invalid and dropped before the record.
  # - F4: an artifact write / patch was rejected for missing element
  #   ids and never reached the record.
  #
  # The driver does not trust the reply on any of these — it checks
  # the RECORD. On any defect it makes ONE correction call inside
  # the same turn, naming exactly what is owed; the correction's
  # content lands like any reply. Defects that survive the
  # correction stay visible: the turn reports "degraded" and the
  # shortfall rides in the turn result. Nothing is ever faked into
  # the record to close a gap (a judgement is the AI's call, per D6;
  # code does not invent one).

  defp defect_view(applied, reply) do
    %{
      reply: reply,
      invalid_questions_dropped: applied.invalid_questions_dropped,
      rejected_artifacts: applied.rejected_artifacts,
      rejected_patches: applied.rejected_patches
    }
  end

  defp turn_defects(view, pending, start_versions) do
    %{
      unresolved_provisional:
        Enum.filter(pending, &(&1 in Record.provisional_question_keys())),
      question_mismatch: question_mismatch(view.reply),
      invalid_questions: view.invalid_questions_dropped,
      artifact_rejected: stale?(view.rejected_artifacts, start_versions),
      patch_rejected: stale?(view.rejected_patches, start_versions)
    }
  end

  defp defects?(defects) do
    defects.unresolved_provisional != [] or defects.question_mismatch != nil or
      defects.invalid_questions > 0 or defects.artifact_rejected or defects.patch_rejected
  end

  # An artifact/patch rejection is still a defect while the rejected
  # name's version has not moved since the turn started — a
  # correction that lands the content (under any version) clears it.
  defp stale?(names, start_versions) do
    Enum.any?(names, fn name ->
      DesignSprite.Artifacts.current_version(name) == Map.get(start_versions, name)
    end)
  end

  defp artifact_versions do
    Map.new(DesignSprite.Artifacts.names(), fn name ->
      {name, DesignSprite.Artifacts.current_version(name)}
    end)
  end

  defp question_mismatch(reply) do
    declared = reply["questions_posted"]
    questions = reply["questions"]

    if is_integer(declared) and is_list(questions) and declared != length(questions) do
      %{declared: declared, emitted: length(questions)}
    end
  end

  defp correct_turn(applied, defects, pending, start_versions, system, trigger) do
    if defects?(defects) do
      context = Prompt.build_context() <> correction_note(defects)

      with {:ok, reply2} <- Client.generate(system, context, reply_schema()),
           {:ok, applied2} <- apply_reply(reply2, trigger) do
        merged = merge_applied(applied, applied2)

        view = %{
          reply: reply2,
          invalid_questions_dropped: applied2.invalid_questions_dropped,
          rejected_artifacts: merged.rejected_artifacts,
          rejected_patches: merged.rejected_patches
        }

        {merged, turn_defects(view, pending, start_versions)}
      else
        _ -> {applied, defects}
      end
    else
      {applied, defects}
    end
  end

  defp merge_applied(a, b) do
    %{
      messages: a.messages ++ b.messages,
      actions: a.actions ++ b.actions,
      score_judgements: a.score_judgements ++ b.score_judgements,
      questions: a.questions ++ b.questions,
      patches: a.patches ++ b.patches,
      sharp: a.sharp or b.sharp,
      sharp_requested: a.sharp_requested or b.sharp_requested,
      questions_dropped: a.questions_dropped + b.questions_dropped,
      invalid_questions_dropped: a.invalid_questions_dropped + b.invalid_questions_dropped,
      artifacts_rejected: a.artifacts_rejected + b.artifacts_rejected,
      rejected_artifacts: Enum.uniq(a.rejected_artifacts ++ b.rejected_artifacts),
      rejected_patches: Enum.uniq(a.rejected_patches ++ b.rejected_patches)
    }
  end

  defp correction_note(defects) do
    lines =
      []
      |> add_line(defects.unresolved_provisional != [], fn ->
        "- Provisional scores still unjudged: #{Enum.join(defects.unresolved_provisional, ", ")}. " <>
          "For EACH one, return a score_judgements entry in this reply: the same result with reason \"comment_reviewed\", " <>
          "or a superseding miss with reason \"comment\". Prose does not judge a score — only the structured entry does."
      end)
      |> add_line(defects.question_mismatch != nil, fn ->
        mismatch = defects.question_mismatch

        "- Your messages announced #{mismatch.declared} new question(s) but the structured reply carried #{mismatch.emitted}. " <>
          "A question exists only as an object in \"questions\": include the missing question object(s) in full, " <>
          "or correct the announcement in a message."
      end)
      |> add_line(defects.invalid_questions > 0, fn ->
        "- #{defects.invalid_questions} question object(s) in your reply were invalid and never reached the record. " <>
          "If one was a genuinely new axis, resend it as a complete, valid question object."
      end)
      |> add_line(defects.artifact_rejected, fn ->
        "- Your artifact was rejected and never reached the record: its meaningful elements lack stable ids. " <>
          "Resend the full artifact with id attributes on its meaningful elements (header, main, section, headings, links, buttons, form controls)."
      end)
      |> add_line(defects.patch_rejected, fn ->
        "- Your artifact patch was dropped: its replacement introduces structure without stable ids. " <>
          "Resend the patch with id attributes on the new meaningful elements in \"replace\"."
      end)

    "\n\n# CORRECTION — required before this turn can close\n" <>
      "Your previous reply this turn left the record short of what it owed or announced. " <>
      "Fix exactly these items in this reply; content that already landed is in the record above — do not repeat it.\n" <>
      Enum.join(lines, "\n")
  end

  defp add_line(lines, false, _fun), do: lines
  defp add_line(lines, true, fun), do: lines ++ [fun.()]

  # The structured-output schema for one driver turn (ReqLLM
  # generate_object). Deliberately loose where the model needs room
  # (prediction/recommended carry no type: a value, a list of values
  # for multi, or null) and strict about the envelope. Counts and
  # semantics (2–4 options, prediction is an option, unique values…)
  # are enforced in Elixir by Record.validate_question/apply_reply —
  # the schema is a shape guarantee, not the validator.
  defp reply_schema do
    # Anthropic's structured-output schema subset requires an explicit
    # type on EVERY property (a description-only property is a 400) and
    # nullable/union types are expressed as anyOf, not type arrays.
    nullable_string = %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
    value_or_values = %{"anyOf" => [%{"type" => "string"}, %{"type" => "array", "items" => %{"type" => "string"}}]}

    option = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["value", "label"],
      "properties" => %{
        "value" => %{"type" => "string"},
        "label" => %{"type" => "string"},
        "preview" => nullable_string
      }
    }

    question = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["key", "type", "prompt", "options", "prediction"],
      "properties" => %{
        "key" => %{"type" => "string"},
        "axis" => nullable_string,
        "type" => %{"type" => "string", "enum" => ["single", "multi", "preview"]},
        "prompt" => %{"type" => "string"},
        "context" => nullable_string,
        "options" => %{"type" => "array", "items" => option},
        "prediction" =>
          Map.put(value_or_values, "description", "the predicted option value, or a list of values for multi"),
        "recommended" => %{
          "description" => "the recommended option value (list for multi), or null",
          "anyOf" => [
            %{"type" => "string"},
            %{"type" => "array", "items" => %{"type" => "string"}},
            %{"type" => "null"}
          ]
        },
        "load_bearing" => %{"type" => "boolean"}
      }
    }

    action = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["action", "question_key", "evidence"],
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["skip", "strike"]},
        "question_key" => %{"type" => "string"},
        "evidence" => %{"type" => "string"}
      }
    }

    score_judgement = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["question_key", "result", "reason"],
      "properties" => %{
        "question_key" => %{"type" => "string"},
        "result" => %{"type" => "string", "enum" => ["hit", "miss"]},
        "reason" => %{"type" => "string"}
      }
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["messages", "actions", "score_judgements", "questions", "artifact", "artifact_patch", "model", "sharp", "questions_posted"],
      "properties" => %{
        "messages" => %{"type" => "array", "items" => %{"type" => "string"}},
        "actions" => %{"type" => "array", "items" => action},
        "score_judgements" => %{"type" => "array", "items" => score_judgement},
        "questions" => %{"type" => "array", "items" => question},
        "artifact" => %{
          "anyOf" => [
            %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["name", "html"],
              "properties" => %{
                "name" => %{"type" => "string"},
                "html" => %{"type" => "string"}
              }
            },
            %{"type" => "null"}
          ]
        },
        "model" => nullable_string,
        "artifact_patch" => %{
          "anyOf" => [
            %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["name", "find", "replace"],
              "properties" => %{
                "name" => %{"type" => "string"},
                "find" => %{"type" => "string"},
                "replace" => %{"type" => "string"},
                "element" => nullable_string
              }
            },
            %{"type" => "null"}
          ]
        },
        "sharp" => %{"type" => "boolean"},
        "questions_posted" => %{
          "type" => "integer",
          "description" => "the number of question objects in this reply's questions array"
        }
      }
    }
  end

  defp apply_reply(reply, trigger) do
    messages = reply["messages"] || []
    actions = reply["actions"] || []
    score_judgements = reply["score_judgements"] || []
    questions = reply["questions"] || []

    # Validate everything before writing anything: a half-applied
    # turn must never reach the record.
    cond do
      not is_list(messages) or not Enum.all?(messages, &is_binary/1) ->
        {:error, :reply_messages_invalid}

      not is_list(actions) ->
        {:error, :reply_actions_invalid}

      not is_list(score_judgements) ->
        {:error, :reply_score_judgements_invalid}

      not is_list(questions) ->
        {:error, :reply_questions_invalid}

      length(questions) > 4 ->
        {:error, :reply_too_many_questions}

      true ->
        actions = valid_actions(actions, trigger)
        score_judgements = valid_score_judgements(score_judgements)
        {questions, questions_dropped, invalid_dropped} = valid_questions(questions)
        patch = valid_patch(reply["artifact_patch"], reply["artifact"])
        patch_rejected = patch_ids_rejection(reply["artifact_patch"], reply["artifact"])

        applied_actions = apply_actions(actions, trigger)
        applied_judgements = apply_score_judgements(score_judgements)

        Enum.each(messages, fn text -> Record.post_message("ai", text) end)
        Enum.each(questions, fn q -> Record.post_question("ai", q) end)

        artifact_outcome = apply_artifact(reply["artifact"])
        applied_patches = apply_artifact_patch(patch)
        apply_model(reply["model"])

        sharp =
          reply["sharp"] == true and questions == [] and Record.sharpness_ready?()

        if sharp do
          Record.declare_sharp("ai")
        end

        rejected_artifacts =
          case artifact_outcome do
            {:rejected, name} -> [name]
            _ -> []
          end

        rejected_patches = if patch_rejected, do: [patch_rejected], else: []

        {:ok,
         %{
           messages: messages,
           actions: applied_actions,
           score_judgements: applied_judgements,
           questions: questions,
           patches: applied_patches,
           sharp: sharp,
           sharp_requested: reply["sharp"] == true,
           questions_dropped: questions_dropped,
           invalid_questions_dropped: invalid_dropped,
           artifacts_rejected: length(rejected_artifacts) + length(rejected_patches),
           rejected_artifacts: rejected_artifacts,
           rejected_patches: rejected_patches
         }}
    end
  end

  defp valid_questions(questions) do
    views = Record.question_views()
    existing_keys = MapSet.new(views, & &1.key)

    closed_axes =
      views
      |> Enum.filter(&(&1.state in [:answered, :struck]))
      |> Enum.map(&normalize_axis(&1.question["axis"] || &1.key))
      |> MapSet.new()

    open_axes =
      views
      |> Enum.filter(&(&1.state in [:open, :skipped]))
      |> Enum.map(&normalize_axis(&1.question["axis"] || &1.key))
      |> MapSet.new()

    # Returns {valid, dropped, invalid}: every emitted-but-dropped
    # question is counted, and INVALID drops (a malformed object for
    # what may be a genuinely new axis) are counted separately from
    # benign ones (duplicates of axes the record already carries) —
    # pilot finding F2: a dropped question must never be
    # indistinguishable from one the model never sent.
    {valid, _seen_keys, _seen_axes, dropped, invalid} =
      Enum.reduce(questions, {[], existing_keys, open_axes, 0, 0}, fn q,
                                                                      {acc, seen_keys, seen_axes,
                                                                       dropped, invalid} ->
        key = is_map(q) && q["key"]
        axis = is_map(q) && normalize_axis(q["axis"] || q["key"] || "")

        cond do
          not is_map(q) ->
            {acc, seen_keys, seen_axes, dropped + 1, invalid + 1}

          MapSet.member?(seen_keys, key) ->
            {acc, seen_keys, seen_axes, dropped + 1, invalid}

          MapSet.member?(closed_axes, axis) ->
            {acc, seen_keys, seen_axes, dropped + 1, invalid}

          MapSet.member?(seen_axes, axis) ->
            {acc, seen_keys, seen_axes, dropped + 1, invalid}

          Record.validate_question(q) != :ok ->
            {acc, seen_keys, seen_axes, dropped + 1, invalid + 1}

          true ->
            {[q | acc], MapSet.put(seen_keys, key), MapSet.put(seen_axes, axis), dropped, invalid}
        end
      end)

    {Enum.reverse(valid), dropped, invalid}
  end

  defp normalize_axis(axis) when is_binary(axis) do
    axis
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize_axis(_axis), do: ""

  # A chat action is the AI's interpretation of the Driver's own
  # latest utterance, not an AI decision in its own right. The
  # deterministic checks keep that interpretation tethered to the
  # record: the target must predate the utterance, the evidence must
  # be an exact quote from it, and the same utterance cannot be
  # interpreted twice for the same question.
  defp valid_actions(_actions, nil), do: []

  defp valid_actions(actions, trigger) do
    entries = Record.entries()

    actions
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(& &1["question_key"])
    |> Enum.flat_map(fn
      {_key, [action]} -> [action]
      {_key, _conflicting_or_duplicate} -> []
    end)
    |> Enum.filter(fn action ->
      key = action["question_key"]
      evidence = action["evidence"]
      view = is_binary(key) && Record.question_view(key)

      with true <- action["action"] in ["skip", "strike"],
           true <- is_binary(evidence) and byte_size(String.trim(evidence)) >= 3,
           true <- is_binary(trigger.body) and String.contains?(trigger.body, evidence),
           true <- view != nil and view != false,
           true <- view.asked_seq < trigger.seq,
           false <-
             Enum.any?(entries, fn entry ->
               entry.seq > trigger.seq and entry.kind == action["action"] and
                 entry.payload["question_key"] == key
             end) do
        case {action["action"], view.state} do
          {"skip", :open} -> true
          {"strike", state} when state in [:open, :skipped] -> true
          _other -> false
        end
      else
        _ -> false
      end
    end)
  end

  defp apply_actions(actions, trigger) do
    Enum.flat_map(actions, fn action ->
      key = action["question_key"]

      result =
        case action["action"] do
          "skip" -> Record.skip_question(key, "human", trigger.body)
          "strike" -> Record.strike_question(key, "human", trigger.body)
        end

      case result do
        {:ok, _entry} -> [action]
        _other -> []
      end
    end)
  end

  defp valid_score_judgements(judgements) do
    judgements
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(& &1["question_key"])
    |> Enum.filter(fn judgement ->
      key = judgement["question_key"]
      view = is_binary(key) && Record.question_view(key)

      view != nil and view != false and view.state == :answered and view.score != nil and
        view.score["provisional"] == true and judgement["result"] in ["hit", "miss"] and
        is_binary(judgement["reason"]) and String.trim(judgement["reason"]) != ""
    end)
  end

  defp apply_score_judgements(judgements) do
    Enum.flat_map(judgements, fn judgement ->
      case Record.supersede_score(
             judgement["question_key"],
             judgement["result"],
             judgement["reason"],
             "ai"
           ) do
        {:ok, _entry} -> [judgement]
        _other -> []
      end
    end)
  end

  # Returns :none (no artifact in the reply, or a storage refusal
  # that is not the ids defect), :written, or {:rejected, name} when
  # the write was refused for missing element ids (F4) — the caller
  # folds a rejection into the turn's defects so it is corrected or
  # surfaced, never silent.
  defp apply_artifact(nil), do: :none

  defp apply_artifact(%{"name" => name, "html" => html})
       when is_binary(name) and is_binary(html) do
    case DesignSprite.Artifacts.write_new(name, html, "ai") do
      {:ok, version} ->
        Record.append_artifact_entry(name, version, "ai")
        :written

      {:error, :artifact_ids_missing} ->
        {:rejected, DesignSprite.Artifacts.sanitize_name(name)}

      _ ->
        :none
    end
  end

  defp apply_artifact(_), do: :none

  # A patch is validated against the CURRENT artifact bytes before
  # anything in the turn is written (same discipline as questions):
  # the target must occur exactly once. A full artifact for the same
  # name in the same reply supersedes the patch — the patch's target
  # was written against the old bytes and can no longer be trusted.
  defp valid_patch(patch, full_artifact) do
    full_name =
      case full_artifact do
        %{"name" => name} when is_binary(name) -> DesignSprite.Artifacts.sanitize_name(name)
        _ -> nil
      end

    cond do
      not is_map(patch) ->
        nil

      not is_binary(patch["name"]) or not is_binary(patch["find"]) or
          not is_binary(patch["replace"]) ->
        nil

      DesignSprite.Artifacts.sanitize_name(patch["name"]) == full_name and full_name != nil ->
        nil

      DesignSprite.Artifacts.patch_check(patch["name"], patch["find"]) != :ok ->
        nil

      not DesignSprite.Artifacts.fragment_ids_sufficient?(patch["replace"]) ->
        nil

      true ->
        patch
    end
  end

  # The sanitized name of a patch dropped ONLY for its replacement's
  # missing ids — every other validity check passes. (A patch dropped
  # for any other reason is not an ids defect: ids were not what kept
  # it from the record.)
  defp patch_ids_rejection(patch, full_artifact) do
    full_name =
      case full_artifact do
        %{"name" => name} when is_binary(name) -> DesignSprite.Artifacts.sanitize_name(name)
        _ -> nil
      end

    cond do
      not is_map(patch) ->
        nil

      not is_binary(patch["name"]) or not is_binary(patch["find"]) or
          not is_binary(patch["replace"]) ->
        nil

      DesignSprite.Artifacts.sanitize_name(patch["name"]) == full_name and full_name != nil ->
        nil

      DesignSprite.Artifacts.patch_check(patch["name"], patch["find"]) != :ok ->
        nil

      DesignSprite.Artifacts.fragment_ids_sufficient?(patch["replace"]) ->
        nil

      true ->
        DesignSprite.Artifacts.sanitize_name(patch["name"])
    end
  end

  defp apply_artifact_patch(nil), do: []

  defp apply_artifact_patch(patch) do
    case DesignSprite.Artifacts.patch(patch["name"], patch["find"], patch["replace"], "ai") do
      {:ok, version} ->
        extra =
          case patch["element"] do
            el when is_binary(el) and el != "" -> %{"patch" => true, "element" => el}
            _ -> %{"patch" => true}
          end

        Record.append_artifact_entry(patch["name"], version, "ai", extra)
        [patch]

      _ ->
        []
    end
  end

  defp apply_model(nil), do: :ok

  defp apply_model(text) when is_binary(text) do
    if String.trim(text) != "" and text != ProjectFiles.model_text() do
      case ProjectFiles.write(ProjectFiles.model_path(), text, "ai") do
        {:ok, version} ->
          Record.append("model", "ai", nil, %{
            "path" => ProjectFiles.model_path(),
            "version" => version
          })

        _ ->
          :ok
      end
    end

    :ok
  end

  defp apply_model(_), do: :ok
end
