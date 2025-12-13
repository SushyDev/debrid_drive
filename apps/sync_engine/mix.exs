defmodule SyncEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :sync_engine,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SyncEngine.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:vfs, in_umbrella: true},
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.13"},
      {:req, "~> 0.5.0"},
      {:floki, "~> 0.38.0"},
      {:real_debrid_ex, github: "sushydev/real_debrid_ex"}
    ]
  end
end
