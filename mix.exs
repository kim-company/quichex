defmodule Quichex.MixProject do
  use Mix.Project

  def project do
    [
      app: :quichex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      source_url: github_url(),
      homepage_url: github_url(),
      docs: docs(),
      package: package(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.37.1"},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Rustler-based bindings that expose the Cloudflare quiche QUIC stack to Elixir."
  end

  defp github_url, do: "https://github.com/kim_company/quichex"

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: github_url()
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "native",
        "priv",
        "mix.exs",
        "README.md",
        "LICENSE"
      ],
      licenses: ["MIT"],
      maintainers: ["KIM Keep In Mind GmbH"],
      links: %{"GitHub" => github_url()}
    ]
  end
end
