defmodule DesignSprite.Api do
  @moduledoc """
  The external-driver surface (contract item 1: FULL parity). Every
  capability the web UI and the built-in AI have, as plain functions
  over the same Record / Artifacts / ProjectFiles actions — the REST
  controller and the MCP controller are both thin skins over this
  module, so the surfaces can never drift.

  The one-Driver rule applies identically: reads are open to anyone;
  every mutation requires the caller to hold the Driver lease
  (DriverLock, D2: API holders heartbeat instead of Presence; a
  mutating call refreshes the lease). The lease is identified by a
  caller-chosen `driver_id` string sent with each call.

  Actor semantics mirror the web: a mutation performed as the human
  (a message, an answer) kicks the built-in AI driver, exactly like
  the LiveView does; a mutation performed as the agent means the
  agent is itself driving, so the built-in driver stays out of the
  way.
  """

  alias DesignSprite.{Artifacts, DriverLock, Export, ProjectFiles, Record}
  alias DesignSprite.AI.Driver

  # ----------------------------------------------------------------
  # Reads (no lease)

  def state do
    base = Export.record_map()

    {:ok,
     Map.merge(base, %{
       "driver" => DriverLock.holder(),
       "driver_status" => to_string(Driver.status().state),
       "sharp_status" => sharp_status_map(Record.sharpness_status())
     })}
  end

  def files do
    {:ok, %{"files" => Enum.map(Export.exportable_files(), &Export.file_map_pub/1)}}
  end

  def read_file(path, version \\ :latest) do
    if version != :latest and not (is_integer(version) and version >= 0) do
      {:error, :not_found}
    else
      read_file_checked(path, version)
    end
  end

  defp read_file_checked(path, version) do
    case Export.read(path, version) do
      {:ok, bytes} -> {:ok, %{"path" => path, "content_type" => Export.content_type(path), "bytes" => bytes}}
      {:error, _} = err -> err
    end
  end

  def export_bundle, do: Export.bundle()

  # ----------------------------------------------------------------
  # The Driver lease

  def acquire_driver(driver_id) do
    if valid_id?(driver_id) do
      case DriverLock.acquire(driver_id) do
        :ok -> {:ok, %{"driver" => driver_id}}
        {:error, :held, _other} -> {:error, :driver_held}
      end
    else
      {:error, :driver_id_required}
    end
  end

  def heartbeat_driver(driver_id) do
    case DriverLock.heartbeat(driver_id) do
      :ok -> {:ok, %{"driver" => driver_id}}
      {:error, :not_held} -> {:error, :driver_not_held}
    end
  end

  def release_driver(driver_id) do
    if DriverLock.held_by?(driver_id) do
      DriverLock.release(driver_id)
      {:ok, %{"driver" => nil}}
    else
      {:error, :driver_not_held}
    end
  end

  def driver, do: {:ok, %{"driver" => DriverLock.holder()}}

  # ----------------------------------------------------------------
  # Mutations (lease required)

  def create_project(driver_id, want) do
    with_driver(driver_id, fn ->
      case Record.create_project(want) do
        {:ok, project} ->
          Driver.kick()
          {:ok, %{"project" => Export.project_map(project)}}

        {:error, _} = err ->
          err
      end
    end)
  end

  def post_message(driver_id, attrs) do
    actor = actor_or(attrs, "agent")

    with_driver(driver_id, fn ->
      text = attrs["text"]

      cond do
        actor == :invalid ->
          {:error, :actor_invalid}

        not is_binary(text) or String.trim(text) == "" ->
          {:error, :text_required}

        true ->
          case Record.post_message(actor, text, attrs["elements"] || []) do
            {:ok, entry} ->
              if actor == "human", do: Driver.kick()
              {:ok, %{"entry" => Export.entry_map(entry)}}

            {:error, _} = err ->
              err
          end
      end
    end)
  end

  def post_question(driver_id, question) do
    with_driver(driver_id, fn ->
      case Record.post_question("agent", question) do
        {:ok, entry} -> {:ok, %{"entry" => Export.entry_map(entry)}}
        {:error, _} = err -> err
      end
    end)
  end

  def answer_question(driver_id, key, attrs) do
    actor = actor_or(attrs, "human")

    with_driver(driver_id, fn ->
      if actor == :invalid do
        {:error, :actor_invalid}
      else
        case Record.answer_question(key, attrs, actor) do
          {:ok, %{answer: answer, score: score}} ->
            if actor == "human", do: Driver.kick()

            {:ok,
             %{
               "answer" => Export.entry_map(answer),
               "score" => Export.entry_map(score)
             }}

          {:error, _} = err ->
            err
        end
      end
    end)
  end

  def skip_question(driver_id, key, attrs) do
    actor = actor_or(attrs, "agent")

    with_driver(driver_id, fn ->
      if actor == :invalid do
        {:error, :actor_invalid}
      else
        case Record.skip_question(key, actor, attrs["note"]) do
          {:ok, entry} ->
            if actor == "human", do: Driver.kick()
            {:ok, %{"entry" => Export.entry_map(entry)}}

          {:error, _} = err ->
            err
        end
      end
    end)
  end

  def strike_question(driver_id, key, attrs) do
    actor = actor_or(attrs, "agent")

    with_driver(driver_id, fn ->
      if actor == :invalid do
        {:error, :actor_invalid}
      else
        case Record.strike_question(key, actor, attrs["note"]) do
          {:ok, entry} ->
            if actor == "human", do: Driver.kick()
            {:ok, %{"entry" => Export.entry_map(entry)}}

          {:error, _} = err ->
            err
        end
      end
    end)
  end

  def judge_score(driver_id, key, attrs) do
    with_driver(driver_id, fn ->
      result = attrs["result"]
      reason = attrs["reason"]

      cond do
        result not in ["hit", "miss"] ->
          {:error, :result_invalid}

        not is_binary(reason) or String.trim(reason) == "" ->
          {:error, :reason_required}

        true ->
          case Record.supersede_score(key, result, reason, "agent") do
            {:ok, entry} -> {:ok, %{"entry" => Export.entry_map(entry)}}
            {:error, _} = err -> err
          end
      end
    end)
  end

  @doc "Append to Decided-for-you — the one design-adjacent write that survives Commit."
  def append_decision(driver_id, text) do
    with_driver(driver_id, fn ->
      if is_binary(text) and String.trim(text) != "" do
        case Record.append_decision("agent", text) do
          {:ok, entry} -> {:ok, %{"entry" => Export.entry_map(entry)}}
          {:error, _} = err -> err
        end
      else
        {:error, :text_required}
      end
    end)
  end

  def write_artifact(driver_id, name, html) do
    with_driver(driver_id, fn ->
      cond do
        not is_binary(name) or Artifacts.sanitize_name(name) in [nil, ""] ->
          {:error, :artifact_name_required}

        not is_binary(html) ->
          {:error, :artifact_html_required}

        true ->
          with {:ok, version} <- Artifacts.write_new(name, html, "agent"),
               {:ok, _entry} <- Record.append_artifact_entry(name, version, "agent") do
            {:ok, %{"name" => Artifacts.sanitize_name(name), "version" => version}}
          end
      end
    end)
  end

  def patch_artifact(driver_id, name, attrs) do
    with_driver(driver_id, fn ->
      find = attrs["find"]
      replace = attrs["replace"]

      cond do
        not is_binary(find) or find == "" ->
          {:error, :patch_find_required}

        not is_binary(replace) ->
          {:error, :patch_replace_required}

        true ->
          case Artifacts.patch(name, find, replace, "agent") do
            {:ok, version} ->
              extra =
                case attrs["element"] do
                  el when is_binary(el) and el != "" -> %{"patch" => true, "element" => el}
                  _ -> %{"patch" => true}
                end

              Record.append_artifact_entry(name, version, "agent", extra)
              {:ok, %{"name" => Artifacts.sanitize_name(name), "version" => version}}

            {:error, _} = err ->
              err
          end
      end
    end)
  end

  def snapshot_artifact(driver_id, name, html) do
    with_driver(driver_id, fn ->
      case Record.snapshot_artifact(name || "", html, "agent") do
        {:ok, _entry} -> {:ok, %{"name" => Artifacts.sanitize_name(name), "version" => 0}}
        {:error, _} = err -> err
      end
    end)
  end

  @doc "Write the decision model (the external-driver equivalent of the built-in AI's re-derivation)."
  def write_model(driver_id, text) do
    with_driver(driver_id, fn ->
      if is_binary(text) and String.trim(text) != "" do
        with {:ok, version} <- ProjectFiles.write(ProjectFiles.model_path(), text, "agent"),
             {:ok, _} <-
               Record.append("model", "agent", nil, %{
                 "path" => ProjectFiles.model_path(),
                 "version" => version
               }) do
          {:ok, %{"path" => ProjectFiles.model_path(), "version" => version}}
        end
      else
        {:error, :text_required}
      end
    end)
  end

  @doc "Declare sharpness — the deterministic gate disposes, exactly as for the built-in AI."
  def declare_sharp(driver_id) do
    with_driver(driver_id, fn ->
      if Record.sharpness_ready?() do
        case Record.declare_sharp("agent") do
          {:ok, _} -> {:ok, %{"sharp" => true}}
          {:error, _} = err -> err
        end
      else
        {:error, :sharpness_gate}
      end
    end)
  end

  def resume(driver_id) do
    with_driver(driver_id, fn ->
      case Record.resume() do
        {:ok, _} ->
          Driver.kick()
          {:ok, %{"sharp" => false}}

        {:error, _} = err ->
          err
      end
    end)
  end

  @doc "Commit the Project (the deliberate handoff press, via the API)."
  def commit(driver_id) do
    with_driver(driver_id, fn ->
      case Record.commit("agent") do
        {:ok, project} -> {:ok, %{"project" => Export.project_map(project)}}
        {:error, _} = err -> err
      end
    end)
  end

  # ----------------------------------------------------------------

  defp with_driver(driver_id, fun) do
    cond do
      not valid_id?(driver_id) ->
        {:error, :driver_id_required}

      DriverLock.holder() == nil ->
        {:error, :driver_required}

      not DriverLock.held_by?(driver_id) ->
        {:error, :driver_held}

      true ->
        result = fun.()
        if match?({:ok, _}, result), do: DriverLock.heartbeat(driver_id)
        result
    end
  end

  defp valid_id?(id), do: is_binary(id) and String.trim(id) != ""

  defp actor_or(attrs, default) do
    case attrs["actor"] || default do
      a when a in ["human", "agent"] -> a
      _ -> :invalid
    end
  end

  defp sharp_status_map(status) do
    %{
      "eligible" => status.eligible,
      "answered_load_bearing" => status.answered_load_bearing,
      "recent_results" => status.recent_results,
      "recent_provisional" => status.recent_provisional,
      "blocking_open_or_skipped" => status.blocking_open_or_skipped
    }
  end
end
