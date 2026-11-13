defmodule DesignSpriteWeb.Auth do
  @moduledoc "Bearer-token check for the API/MCP endpoints (token file is the source of truth, read per request — the v1 pattern)."
  import Plug.Conn

  def authorized?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token == DesignSprite.Token.current()
      _ -> false
    end
  end

  def unauthorized(conn) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{"error" => "unauthorized"})
    |> halt()
  end
end
