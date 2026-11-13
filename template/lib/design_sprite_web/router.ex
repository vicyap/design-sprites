defmodule DesignSpriteWeb.Router do
  use DesignSpriteWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {DesignSpriteWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", DesignSpriteWeb do
    pipe_through(:browser)

    live("/", ProjectLive)
    get("/artifact/:name", ArtifactController, :show)
    get("/artifact/:name/v/:version", ArtifactController, :show_version)
    # File explorer downloads: the bundle + raw exportable files.
    get("/export", FilesController, :export)
    get("/files/raw", FilesController, :raw)
    # sendBeacon draft flush (pagehide) — browser pipeline for session+CSRF.
    post("/api/draft", DraftController, :save)
  end

  scope "/", DesignSpriteWeb do
    pipe_through(:api)

    get("/health", ApiController, :health)

    # External-driver parity surface (Bearer admin token; the
    # one-Driver lease applies to every mutation). See DesignSprite.Api.
    get("/api/state", ProjectApiController, :state)
    get("/api/files", ProjectApiController, :files)
    get("/api/files/content", ProjectApiController, :file_content)
    get("/api/export", ProjectApiController, :export)
    post("/api/project", ProjectApiController, :create_project)
    get("/api/driver", ProjectApiController, :driver)
    post("/api/driver/acquire", ProjectApiController, :acquire_driver)
    post("/api/driver/heartbeat", ProjectApiController, :heartbeat_driver)
    post("/api/driver/release", ProjectApiController, :release_driver)
    post("/api/messages", ProjectApiController, :post_message)
    post("/api/questions", ProjectApiController, :post_question)
    post("/api/questions/:key/answer", ProjectApiController, :answer_question)
    post("/api/questions/:key/skip", ProjectApiController, :skip_question)
    post("/api/questions/:key/strike", ProjectApiController, :strike_question)
    post("/api/questions/:key/score", ProjectApiController, :judge_score)
    post("/api/decisions", ProjectApiController, :append_decision)
    post("/api/artifacts", ProjectApiController, :write_artifact)
    post("/api/artifacts/snapshot", ProjectApiController, :snapshot_artifact)
    post("/api/artifacts/:name/patch", ProjectApiController, :patch_artifact)
    post("/api/model", ProjectApiController, :write_model)
    post("/api/sharp", ProjectApiController, :declare_sharp)
    post("/api/resume", ProjectApiController, :resume)
    post("/api/commit", ProjectApiController, :commit)

    # MCP: the same parity surface as JSON-RPC tools.
    post("/mcp", McpController, :handle)
  end
end
