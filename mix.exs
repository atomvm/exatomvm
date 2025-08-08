defmodule ExAtomVM.MixProject do
  use Mix.Project

  def project do
    [
      app: :exatomvm,
      version: "0.1.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "ExAtomVM",
      source_url: "https://github.com/atomvm/exatomvm",
      homepage_url: "https://www.atomvm.net/",
      docs: [
        # The main page in the docs
        main: "ExAtomVM",
        # logo: "path/to/logo.png",
        extras: ["README.md"]
      ]
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
      {:uf2tool, "1.1.0", runtime: false},
      {:ex_doc, "~> 0.20", only: :dev, runtime: false},
      {:pythonx, "~> 0.4.0", runtime: false, optional: true},
      {:req, "~> 0.5.0", runtime: false, optional: true}
    ]
  end
end
