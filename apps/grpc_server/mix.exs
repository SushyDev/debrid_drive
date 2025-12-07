defmodule GrpcServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :grpc_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Specifies which paths to compile per environment
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {GrpcServer.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.13"},
      {:stream_mount_api,
       git: "https://github.com/sushydev/stream_mount_api", tag: "v1.3.2", subdir: "gen/elixir"},
      {:vfs, in_umbrella: true},
      {:stream_data, "~> 1.0", only: :test}
    ]
  end
end
