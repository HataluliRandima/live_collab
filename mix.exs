defmodule LiveCollab.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/HataluliRandima/live_collab"

  def project do
    [
      app: :live_collab,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Real-time multiplayer collaborative primitives for Phoenix LiveView",
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        flags: [:error_handling, :extra_return, :missing_return]
      ]
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:jason, "~> 1.2"},

      # Test-only: required by Phoenix.LiveViewTest on LiveView >= 1.1
      {:lazy_html, ">= 0.1.0", only: :test},

      # Tooling
      {:ex_doc, ">= 0.30.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "test --warnings-as-errors"
      ]
    ]
  end

  defp package do
    [
      name: "live_collab",
      maintainers: ["LiveCollab Team"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib assets/js package.json .formatter.exs mix.exs README.md LICENSE* CHANGELOG*)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/security.md",
        "guides/telemetry.md",
        "guides/guarantees.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        "Public API": [
          LiveCollab,
          LiveCollab.LiveView,
          LiveCollab.Components,
          LiveCollab.Telemetry
        ],
        "Collaboration primitives": [
          LiveCollab.Field,
          LiveCollab.Element,
          LiveCollab.Cursor,
          LiveCollab.Viewport,
          LiveCollab.Presence
        ],
        Infrastructure: [LiveCollab.Config, LiveCollab.RateLimiter]
      ]
    ]
  end
end
