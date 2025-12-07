defmodule SyncEngine.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Get gRPC port from config (environment-based)
    grpc_port = Application.get_env(:sync_engine, :grpc_port, 50051)

    children =
      [
        # Start shared RealDebrid client with rate limiting
        SyncEngine.RealDebridClient,
        # Start job queue for async operations
        SyncEngine.JobQueue,
        # Start the gRPC server
        {GRPC.Server.Supervisor,
         endpoint: SyncEngine.Endpoint, port: grpc_port, start_server: true}
      ] ++ poller_child()

    # Use rest_for_one strategy: if a child crashes, all children started AFTER it
    # will also be restarted. This is important because:
    # - JobQueue and Poller depend on RealDebridClient
    # - If RealDebridClient crashes, JobQueue and Poller should also restart
    # - GRPC server can continue independently
    opts = [strategy: :rest_for_one, name: SyncEngine.Supervisor, max_restarts: 3, max_seconds: 5]
    Supervisor.start_link(children, opts)
  end

  # Don't start Poller in test environment to avoid Ecto.Sandbox ownership issues
  defp poller_child do
    # In releases, Mix.env is not available, so we check the application env
    # which is set at compile time
    if Application.get_env(:sync_engine, :start_poller, true) do
      [SyncEngine.Services.Poller]
    else
      []
    end
  end
end
