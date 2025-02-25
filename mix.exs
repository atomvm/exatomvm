defmodule ExAtomVM.MixProject do
  use Mix.Project

  def project do
    [
      app: :exatomvm,
      version: "0.1.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:uf2tool, "1.1.0"},
      {:pythonx, "~> 0.4.0", runtime: false, optional: true},
      {:req, "~> 0.5.0", runtime: false, optional: true}
    ]
  end
end
