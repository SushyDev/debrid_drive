defmodule SyncEngine.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Get gRPC port from config (environment-based)
    grpc_port = Application.get_env(:sync_engine, :grpc_port, 50051)

    # Get the gRPC endpoint module from configuration
    # This allows grpc_server to provide its endpoint without creating a hard dependency
    endpoint_module = Application.get_env(:sync_engine, :grpc_endpoint, GrpcServer.Endpoint)

    # Determine if gRPC server should start (disabled in tests)
    start_grpc_server = Application.get_env(:sync_engine, :start_grpc_server, true)

    # Determine if JobQueue should start (disabled in tests to avoid Ecto.Sandbox issues)
    start_job_queue = Application.get_env(:sync_engine, :start_job_queue, true)

    children =
      [
        # Start shared RealDebrid client with rate limiting
        SyncEngine.RealDebridClient
      ]
      |> maybe_add_job_queue(start_job_queue)
      |> Kernel.++(grpc_server_child(start_grpc_server, endpoint_module, grpc_port))
      |> Kernel.++(poller_child())

    # Use rest_for_one strategy: if a child crashes, all children started AFTER it
    # will also be restarted. This is important because:
    # - JobQueue and Poller depend on RealDebridClient
    # - If RealDebridClient crashes, JobQueue and Poller should also restart
    # - GRPC server can continue independently
    opts = [strategy: :rest_for_one, name: SyncEngine.Supervisor, max_restarts: 3, max_seconds: 5]
    Supervisor.start_link(children, opts)
  end

  # Conditionally add JobQueue if enabled
  defp maybe_add_job_queue(children, true) do
    children ++ [SyncEngine.JobQueue]
  end

  defp maybe_add_job_queue(children, false) do
    children
  end

  # Conditionally add gRPC server if enabled
  defp grpc_server_child(true, endpoint_module, grpc_port) do
    [{GRPC.Server.Supervisor, endpoint: endpoint_module, port: grpc_port, start_server: true}]
  end

  defp grpc_server_child(false, _endpoint_module, _grpc_port) do
    []
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
