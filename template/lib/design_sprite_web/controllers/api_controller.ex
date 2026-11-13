defmodule DesignSpriteWeb.ApiController do
  use DesignSpriteWeb, :controller

  alias DesignSprite.{Record, Store}

  @doc "Real DB round trip; also the Phase-1 probe target."
  def health(conn, _params) do
    ok = Store.health_probe!()
    project = Record.project()

    json(conn, %{
      "ok" => ok,
      "app" => "design_sprite",
      "version" => "2.0.0",
      "project" => project && %{"status" => project.status, "title" => project.title}
    })
  end
end
