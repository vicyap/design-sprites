import Config

if config_env() == :prod do
  database_path = System.get_env("DATABASE_PATH")

  data_dir =
    System.get_env("DATA_DIR") ||
      (database_path && Path.dirname(database_path)) ||
      "/data"

  config :design_sprite, :data_dir, data_dir

  config :design_sprite, DesignSprite.Repo,
    database: database_path || Path.join(data_dir, "app.db"),
    journal_mode: :wal,
    pool_size: 5

  if token_file = System.get_env("ADMIN_TOKEN_FILE") do
    config :design_sprite, :admin_token_file, token_file
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      :crypto.strong_rand_bytes(64) |> Base.encode64()

  # The deployment's real public host, set per sprite at deploy time
  # via data/.env (PHX_HOST). Fallback is for URL generation only;
  # origin CHECKING below does not depend on it.
  phx_host =
    case System.get_env("PHX_HOST") do
      h when h in [nil, "", "__SPRITE_HOST__"] -> "localhost"
      h -> h
    end

  config :design_sprite, DesignSpriteWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT") || "8080")],
    # Sprites serve from *.sprites.app origins; state them explicitly
    # (the v1 fleet bug was check_origin against "localhost"; disabling
    # outright would be worse).
    check_origin: ["https://*.sprites.app", "//localhost"],
    url: [host: phx_host, port: 443, scheme: "https"],
    secret_key_base: secret_key_base,
    server: System.get_env("PHX_SERVER") == "true"

  config :design_sprite, :sprite_name, System.get_env("SPRITE_NAME")

  # The AI driver. Default: the Sprites gateway conn:anthropic client.
  # AI_GATEWAY_URL pins the gateway base URL (ReqLLM appends
  # /v1/messages); AI_MODEL picks the model; AI_ADAPTER=stub exists
  # for local smoke tests only.
  config :design_sprite,
    :ai_adapter,
    if(System.get_env("AI_ADAPTER") == "stub",
      do: DesignSprite.AI.StubClient,
      else: DesignSprite.AI.GatewayClient
    )

  config :design_sprite, :ai_gateway_url, System.get_env("AI_GATEWAY_URL")
  config :design_sprite, :ai_model, System.get_env("AI_MODEL") || "claude-fable-5-2"

  # Optional Commit webhook (never email).
  config :design_sprite, :webhook_url, System.get_env("COMMIT_WEBHOOK_URL")
  config :design_sprite, :webhook_token, System.get_env("COMMIT_WEBHOOK_TOKEN")

  config :logger, level: :info
end

# ReqLLM resolves model ids through LLMDB's packaged catalog, and
# resolution RAISES for unregistered ids. Gateway-only ids (the
# default claude-fable-5-2) are not in the catalog, so register the
# configured model as a custom LLMDB overlay — capabilities cloned
# from the catalog's claude-fable-5 entry. Unconditional (not
# prod-gated): runtime.exs is evaluated before any application
# starts, in every env.
llm_model_id =
  (System.get_env("AI_MODEL") || "claude-fable-5-2")
  |> String.replace_prefix("anthropic:", "")

config :llm_db,
  custom: %{
    anthropic: [
      name: "Anthropic",
      models: %{
        llm_model_id => %{
          capabilities: %{
            chat: true,
            embeddings: false,
            json: %{native: false, schema: false, strict: false},
            reasoning: %{enabled: true},
            rerank: false,
            streaming: %{tool_calls: true},
            tools: %{enabled: true}
          }
        }
      }
    ]
  }
