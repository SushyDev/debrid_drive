import Config

# Configure Logger level from environment variable
# Valid values: debug, info, warning, error
log_level =
  case System.get_env("LOG_LEVEL") do
    level when level in ["debug", "info", "warning", "error"] ->
      String.to_existing_atom(level)

    _ ->
      :info
  end

config :logger, level: log_level

# Runtime configuration for production releases
if config_env() == :prod do
  # Configure database path from environment variable
  database_path =
    System.get_env("DATABASE_PATH") ||
      "/app/data/debrid_stream_prod.db"

  config :vfs, VFS.Repo, database: database_path

  # Configure gRPC port from environment variable
  grpc_port =
    System.get_env("GRPC_PORT")
    |> case do
      nil -> 50051
      port when is_binary(port) -> String.to_integer(port)
    end

  config :sync_engine,
    grpc_port: grpc_port

  # Configure RealDebrid credentials from environment variables
  config :sync_engine,
    real_debrid_token: System.get_env("RD_API_TOKEN"),
    real_debrid_webdav_password: System.get_env("RD_WEBDAV_PASSWORD")
end
