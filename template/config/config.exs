import Config

config :design_sprite, ash_domains: [DesignSprite.Domain]
config :design_sprite, ecto_repos: [DesignSprite.Repo]
config :ash, default_string_length_count: :codepoints

config :design_sprite, DesignSpriteWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DesignSpriteWeb.ErrorHTML, json: DesignSpriteWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DesignSprite.PubSub,
  live_view: [signing_salt: "decision-sprite-live"],
  # Never log answer content: filter every answer-bearing parameter in
  # ALL environments (observability checklist, section 3).
  filter_parameters: [
    "password",
    "token",
    "secret",
    "choice",
    "choice_label",
    "choices",
    "other_text",
    "comment",
    "answer",
    "anything_else",
    "body",
    "text",
    "want",
    "message",
    "payload",
    "html",
    "model"
  ]

# Victor's canonical package list: JSON is the built-in JSON module
# (Elixir 1.18+), not Jason. Jason remains a dep for test helpers.
config :phoenix, :json_library, JSON

config :logger, :console, format: "$message\n", metadata: []

# Crash reports must never carry entry content into the log: OTP
# reports embed a crashed process's last message/state (for a
# LiveView, a form event with the Driver's answer text). Primary
# defence is the :logger primary filter DesignSprite.LogScrub
# installs at boot (it rewrites the event before any handler sees
# it); this translator is the second layer for paths that do
# translate — both render label + name + reason class only.
config :logger, translators: [{DesignSprite.LogScrub, :translate}]

import_config "#{config_env()}.exs"
