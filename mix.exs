defmodule Omni.Agent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/aaronrussell/omni_agent"

  def project do
    [
      app: :omni_agent,
      name: "Omni Agent",
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs(),
      package: pkg()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:omni, path: "../omni"},

      # dev dependencies
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false, warn_if_outdated: true},
      {:plug, "~> 1.0", only: :test}
    ]
  end

  defp docs do
    [
      main: "Omni.Agent",
      source_url: @source_url,
      source_ref: "v#{@version}",
      homepage_url: @source_url,
      extras: ["CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp pkg do
    [
      description: "Stateful LLM agents for Elixir. Multi-turn conversations with lifecycle callbacks, tool approval, and steering. Built on Omni.",
      licenses: ["Apache-2.0"],
      maintainers: ["Aaron Russell"],
      files: ~w(lib .formatter.exs mix.exs CHANGELOG.md LICENSE README.md),
      links: %{
        "GitHub" => @source_url
      }
    ]
  end
end
