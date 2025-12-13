import Config

# Disable SQL query logging in tests
config :logger, level: :warning

# Disable gRPC logging in tests - set logger to only show errors
config :logger, :console,
  level: :warning,
  format: "$time $metadata[$level] $message\n",
  metadata: [:pid, :application, :module]

# Configure the database for test environment to use SQL Sandbox
if config_env() == :test do
  config :vfs, VFS.Repo,
    database: Path.expand("../debrid_stream_test.db", __DIR__),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10,
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    log: false,
    # SQLite concurrency optimizations
    journal_mode: :wal,
    busy_timeout: 5000,
    cache_size: -64000,
    temp_store: :memory,
    synchronous: :normal
end

# Disable Oban queues in test environment
config :sync_engine, Oban,
  repo: VFS.Repo,
  name: Oban,
  notifier: Oban.Notifiers.PG,
  # SQLite doesn't support table prefixes
  prefix: false,
  testing: :inline,
  queues: false,
  plugins: false

# Use port 0 for gRPC server in tests to get random available port
# This prevents port conflicts when running tests with dev server
# Disable gRPC server and background services in tests to avoid Ecto.Sandbox ownership issues
config :sync_engine,
  grpc_port: 0,
  start_poller: false,
  start_grpc_server: false,
  start_job_queue: false
