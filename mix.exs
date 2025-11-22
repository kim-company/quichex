defmodule Quichex.MixProject do
  use Mix.Project

  def project do
    [
      app: :quichex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Quichex.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.37.1"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
