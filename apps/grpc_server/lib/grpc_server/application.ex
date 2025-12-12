defmodule GrpcServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure dependent applications are started
    {:ok, _} = Application.ensure_all_started(:vfs)
    {:ok, _} = Application.ensure_all_started(:sync_engine)

    children = [
      # gRPC server is started by the debrid_drive application
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GrpcServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
