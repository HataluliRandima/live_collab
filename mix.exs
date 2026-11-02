defmodule LiveCollab.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/HataluliRandima/live_collab"

  def project do
    [
      app: :live_collab,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Real-time multiplayer collaborative primitives for Phoenix LiveView",
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, ">= 1.7.0"},
      {:phoenix_live_view, ">= 0.19.0 and < 2.0.0"},
      {:phoenix_pubsub, ">= 2.1.0"},
      {:jason, "~> 1.2"},
      {:ex_doc, ">= 0.30.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "live_collab",
      maintainers: ["LiveCollab Team"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib assets .formatter.exs mix.exs README.md LICENSE* CHANGELOG*)
    ]
  end

  defp docs do
    [
      main: "LiveCollab",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
