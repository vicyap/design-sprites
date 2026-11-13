import Config

test_data =
  Path.join(System.tmp_dir!(), "design_sprite_test_#{:erlang.unique_integer([:positive])}")

File.mkdir_p!(test_data)
config :design_sprite, :data_dir, test_data

config :design_sprite, DesignSprite.Repo,
  database: Path.join(test_data, "app.db"),
  journal_mode: :wal,
  pool_size: 5

config :design_sprite, DesignSpriteWeb.Endpoint,
  http: [port: 4002],
  secret_key_base: "test-only-secret-key-base-0123456789abcdef0123456789abcdef0123456789abcde",
  server: false

# Tests drive the AI through the stub adapter, never the network.
config :design_sprite, :ai_adapter, DesignSprite.AI.StubClient

config :logger, level: :warning
