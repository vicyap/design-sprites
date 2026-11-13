defmodule DesignSpriteWeb.FilesController do
  @moduledoc """
  Web downloads backing the file explorer: the export bundle and raw
  exportable files. Read-only and unauthenticated, like the Project
  page itself and artifact serving — anyone who can view the Project
  can already read every byte these routes serve (the programmatic
  API equivalents stay behind the admin Bearer token). Artifact bytes
  here are the PRISTINE stored bytes — no inspector bridge; what you
  download is what an implementing agent gets.
  """
  use DesignSpriteWeb, :controller

  alias DesignSprite.Export

  def export(conn, _params) do
    case Export.bundle() do
      {:ok, zip, filename} ->
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, zip)

      {:error, :no_project} ->
        conn |> put_status(404) |> text("no project yet")
    end
  end

  def raw(conn, params) do
    version =
      case params["version"] do
        nil -> :latest
        "latest" -> :latest
        v -> case Integer.parse(v) do
               {n, ""} when n >= 0 -> n
               _ -> :invalid
             end
      end

    path = params["path"] || ""

    if version == :invalid do
      conn |> put_status(404) |> text("no such file")
    else
      case Export.read(path, version) do
        {:ok, bytes} ->
          conn
          |> put_resp_content_type(Export.content_type(path))
          |> put_resp_header(
            "content-disposition",
            ~s(attachment; filename="#{Path.basename(path)}")
          )
          |> send_resp(200, bytes)

        {:error, _} ->
          conn |> put_status(404) |> text("no such file")
      end
    end
  end
end
