# Suppress gRPC error logs during tests (expected from error handling tests)
Logger.configure(level: :emergency)
Logger.configure_backend(:console, level: :emergency)

ExUnit.start()

{:ok, _} = Application.ensure_all_started(:vfs)

Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, :manual)

# Clean database at startup if it exists
try do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(VFS.Repo)
  Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, {:shared, self()})

  tables = ["directory_entries", "inodes", "torrent_files", "torrents"]
  Ecto.Adapters.SQL.query!(VFS.Repo, "PRAGMA foreign_keys = OFF", [])
  for table <- tables, do: Ecto.Adapters.SQL.query!(VFS.Repo, "DELETE FROM #{table}", [])
  Ecto.Adapters.SQL.query!(VFS.Repo, "DELETE FROM sqlite_sequence", [])
  Ecto.Adapters.SQL.query!(VFS.Repo, "PRAGMA foreign_keys = ON", [])

  Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, :manual)
rescue
  _ -> :ok
end

# Start gRPC server on random port to avoid conflicts
{:ok, server_pid} =
  GRPC.Server.Supervisor.start_link(
    endpoint: GrpcServer.Endpoint,
    port: 0,
    start_server: true
  )

Application.put_env(:grpc_server, :server_pid, server_pid)
Process.sleep(100)

# Find the actual port Ranch assigned
actual_port =
  try do
    listeners = :ranch.info()

    case Enum.find(listeners, fn {ref, _info} ->
           ref == GrpcServer.Endpoint or to_string(ref) =~ "GrpcServer.Endpoint"
         end) do
      {ref, _info} ->
        case :ranch.get_addr(ref) do
          {_ip, port} -> port
          _ -> 50051
        end

      nil ->
        50051
    end
  rescue
    _ -> 50051
  end

Application.put_env(:grpc_server, :test_port, actual_port)

unless Process.whereis(GRPC.Client.Supervisor) do
  {:ok, _pid} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)
end

defmodule GrpcTestHelper do
  @doc "Truncates all database tables for test isolation"
  def cleanup_database do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(VFS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, {:shared, self()})

    tables = ["directory_entries", "inodes", "torrent_files", "torrents"]

    Ecto.Adapters.SQL.query!(VFS.Repo, "PRAGMA foreign_keys = OFF", [])
    for table <- tables, do: Ecto.Adapters.SQL.query!(VFS.Repo, "DELETE FROM #{table}", [])
    Ecto.Adapters.SQL.query!(VFS.Repo, "DELETE FROM sqlite_sequence", [])
    Ecto.Adapters.SQL.query!(VFS.Repo, "PRAGMA foreign_keys = ON", [])

    :ok
  end

  @doc "Creates root directory if it doesn't exist"
  def ensure_root do
    case VFS.get_root() do
      {:ok, root} -> {:ok, root}
      {:error, _} -> VFS.get_root()
    end
  end

  @doc "Waits for database to be ready, retrying on lock errors"
  def wait_for_db_ready(retries \\ 5) do
    try do
      Ecto.Adapters.SQL.query!(VFS.Repo, "SELECT 1", [])
      :ok
    rescue
      e in Ecto.QueryError ->
        if retries > 0 and String.contains?(Exception.message(e), "database is locked") do
          Process.sleep(100 * (6 - retries))
          wait_for_db_ready(retries - 1)
        else
          reraise e, __STACKTRACE__
        end
    end
  end
end
