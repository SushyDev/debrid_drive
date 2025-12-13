# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Logger
# The log level can be set via LOG_LEVEL environment variable
# Valid values: debug, info, warning, error
# Default: info
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:pid, :application, :module]

config :logger,
  level: :info

# Configure VFS database
config :vfs, VFS.Repo,
  database: Path.expand("../debrid_stream_#{config_env()}.db", __DIR__),
  pool_size: 1,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  log: false,
  journal_mode: :wal,
  busy_timeout: 30000,
  cache_size: -64000,
  temp_store: :memory,
  synchronous: :normal,
  mmap_size: 30_000_000_000,
  pragma_foreign_keys: false,
  pragma_journal_size_limit: 64_000_000

config :vfs,
  ecto_repos: [VFS.Repo]

config :sync_engine,
  vfs_repo: VFS.Repo,
  # RealDebrid credentials - MUST be set via environment variables
  real_debrid_webdav_password: System.get_env("RD_WEBDAV_PASSWORD"),
  real_debrid_token: System.get_env("RD_API_TOKEN"),
  real_debrid_max_requests_per_minute: 50,
  # Torrent sync configuration
  torrents_container_name: "media_manager",
  # How to format torrent directory names: :id, :filename, or :filename_with_id
  torrent_directory_format: :filename,
  # Maximum number of torrents to sync per poll
  sync_limit: 100,
  # gRPC server port - can be overridden by GRPC_PORT env var
  grpc_port: String.to_integer(System.get_env("GRPC_PORT") || "50051"),
  # gRPC endpoint module - injected by grpc_server app at runtime
  grpc_endpoint: GrpcServer.Endpoint

# Import environment specific config
import_config "#{config_env()}.exs"
