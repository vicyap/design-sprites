defmodule DesignSpriteWeb.ProjectApiController do
  @moduledoc """
  The REST skin over DesignSprite.Api (full parity for external
  drivers). Auth: the admin Bearer token on every action. The Driver
  lease is identified per request by the `x-driver-id` header or a
  `driver_id` body field.

  Error mapping: conflicts (committed, already answered, driver held,
  no driver lease) are 409; missing things are 404; everything else
  is a 422 with the domain error name. Response bodies never echo
  request content back.
  """
  use DesignSpriteWeb, :controller

  alias DesignSprite.Api
  alias DesignSpriteWeb.Auth

  plug :require_auth

  defp require_auth(conn, _opts) do
    if Auth.authorized?(conn), do: conn, else: Auth.unauthorized(conn)
  end

  # ----------------------------------------------------------------
  # Reads

  def state(conn, _params) do
    {:ok, state} = Api.state()
    json(conn, state)
  end

  def files(conn, _params) do
    {:ok, result} = Api.files()
    json(conn, result)
  end

  def file_content(conn, params) do
    version = parse_version(params["version"])

    case Api.read_file(params["path"] || "", version) do
      {:ok, %{"content_type" => type, "bytes" => bytes}} ->
        conn
        |> put_resp_content_type(type)
        |> send_resp(200, bytes)

      {:error, _} ->
        conn |> put_status(404) |> json(%{"error" => "not_found"})
    end
  end

  def export(conn, _params) do
    case Api.export_bundle() do
      {:ok, zip, filename} ->
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, zip)

      {:error, :no_project} ->
        conn |> put_status(404) |> json(%{"error" => "no_project"})
    end
  end

  # ----------------------------------------------------------------
  # Driver lease

  def driver(conn, _params) do
    {:ok, result} = Api.driver()
    json(conn, result)
  end

  def acquire_driver(conn, params) do
    respond(conn, Api.acquire_driver(driver_id(conn, params)))
  end

  def heartbeat_driver(conn, params) do
    respond(conn, Api.heartbeat_driver(driver_id(conn, params)))
  end

  def release_driver(conn, params) do
    respond(conn, Api.release_driver(driver_id(conn, params)))
  end

  # ----------------------------------------------------------------
  # Mutations

  def create_project(conn, params) do
    respond(conn, Api.create_project(driver_id(conn, params), params["want"]))
  end

  def post_message(conn, params) do
    respond(conn, Api.post_message(driver_id(conn, params), params))
  end

  def post_question(conn, params) do
    question = params["question"] || params
    respond(conn, Api.post_question(driver_id(conn, params), question))
  end

  def answer_question(conn, %{"key" => key} = params) do
    respond(conn, Api.answer_question(driver_id(conn, params), key, params))
  end

  def skip_question(conn, %{"key" => key} = params) do
    respond(conn, Api.skip_question(driver_id(conn, params), key, params))
  end

  def strike_question(conn, %{"key" => key} = params) do
    respond(conn, Api.strike_question(driver_id(conn, params), key, params))
  end

  def judge_score(conn, %{"key" => key} = params) do
    respond(conn, Api.judge_score(driver_id(conn, params), key, params))
  end

  def append_decision(conn, params) do
    respond(conn, Api.append_decision(driver_id(conn, params), params["text"]))
  end

  def write_artifact(conn, params) do
    respond(conn, Api.write_artifact(driver_id(conn, params), params["name"], params["html"]))
  end

  def patch_artifact(conn, %{"name" => name} = params) do
    respond(conn, Api.patch_artifact(driver_id(conn, params), name, params))
  end

  def snapshot_artifact(conn, params) do
    respond(conn, Api.snapshot_artifact(driver_id(conn, params), params["name"], params["html"]))
  end

  def write_model(conn, params) do
    respond(conn, Api.write_model(driver_id(conn, params), params["text"]))
  end

  def declare_sharp(conn, params) do
    respond(conn, Api.declare_sharp(driver_id(conn, params)))
  end

  def resume(conn, params) do
    respond(conn, Api.resume(driver_id(conn, params)))
  end

  def commit(conn, params) do
    respond(conn, Api.commit(driver_id(conn, params)))
  end

  # ----------------------------------------------------------------

  defp driver_id(conn, params) do
    case get_req_header(conn, "x-driver-id") do
      [id | _] -> id
      [] -> params["driver_id"]
    end
  end

  defp parse_version(nil), do: :latest
  defp parse_version("latest"), do: :latest

  defp parse_version(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> n
      _ -> :invalid
    end
  end

  defp parse_version(_), do: :invalid

  defp respond(conn, {:ok, result}) do
    json(conn, Map.put(result, "ok", true))
  end

  defp respond(conn, {:error, reason}) do
    conn
    |> put_status(status_for(reason))
    |> json(%{"error" => to_string(reason)})
  end

  defp status_for(reason)
       when reason in [
              :committed,
              :already_committed,
              :already_answered,
              :question_struck,
              :driver_held,
              :driver_required,
              :project_exists,
              :artifact_exists,
              :version_exists
            ],
       do: 409

  defp status_for(reason)
       when reason in [:question_not_found, :not_found, :no_project, :no_artifact],
       do: 404

  defp status_for(_reason), do: 422
end
