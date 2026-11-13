defmodule DesignSprite.MixProject do
  use Mix.Project

  def project do
    [
      app: :design_sprite,
      version: "2.0.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: [],
      deps: deps(),
      # Final set reconciled with the usage-rules audit
      # (~/workspace/design/elixir-usage-rules-audit.md): only packages
      # actually in deps AND shipping rules. A plain atom entry syncs
      # the main rules + ALL sub-rules (usage_rules 1.3 default), which
      # covers ash's 16 sub-rules and phoenix's dir-only sub-rules
      # (ecto/elixir/html/liveview). ash_*/phoenix_* packages ship no
      # rules, so the old regex entries contributed nothing.
      usage_rules: [
        file: "AGENTS.md",
        usage_rules: [:elixir, :otp, :ash, :phoenix, :igniter, :req_llm]
      ],
      releases: [
        design_sprite: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {DesignSprite.Application, []},
      # :ssl serves the Req/Finch TLS calls to the Sprites gateway
      # (the AI driver + the Commit webhook). :crypto mints the
      # fallback SECRET_KEY_BASE in runtime.exs.
      extra_applications: [:logger, :runtime_tools, :crypto, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      # Victor's canonical package list (~/workspace/design/elixir-package-list.md):
      # HTTP client = Req; LLM client = ReqLLM (generate_object for structured output).
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.0"},
      {:ash, "~> 3.0"},
      {:ash_sqlite, "~> 0.2"},
      # Dev-only: Ash/Phoenix/Elixir usage rules synced into AGENTS.md
      # (Victor, 2026-11-12; brief addendum). Never in a release.
      {:usage_rules, "~> 1.1", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev]}
    ]
  end
end
