ExUnit.start()

# Start the VFS Repo in sandbox mode for testing
{:ok, _} = Application.ensure_all_started(:vfs)

# Start the gRPC server with port 0 for tests to get a random available port
# This avoids conflicts with any running dev servers on port 50051
{:ok, _server_pid} =
  GRPC.Server.Supervisor.start_link(
    endpoint: GrpcServer.Endpoint,
    port: 0,
    start_server: true
  )

# Wait a moment for the server to fully initialize and get the actual port
Process.sleep(100)

# Get the actual port assigned by the OS
# Since we used port 0, the OS assigned a random available port
# We need to find which port ranch is actually listening on
actual_port =
  try do
    # Ranch registers listeners, we need to find ours
    # The listener is typically registered with a ref that includes the endpoint name
    listeners = :ranch.info()

    # Find our listener by endpoint name
    case Enum.find(listeners, fn {ref, _info} ->
           ref == GrpcServer.Endpoint or to_string(ref) =~ "GrpcServer.Endpoint"
         end) do
      {ref, _info} ->
        case :ranch.get_addr(ref) do
          {_ip, port} -> port
          _ -> 50051
        end

      nil ->
        # Fallback: 50051
        50051
    end
  rescue
    _ -> 50051
  end

# Store the test server port in application env for test helpers to use
Application.put_env(:grpc_server, :test_port, actual_port)

# Start the GRPC Client Supervisor for test clients
unless Process.whereis(GRPC.Client.Supervisor) do
  {:ok, _pid} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)
end

# Set up Ecto Sandbox mode for concurrent test isolation
Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, :manual)
