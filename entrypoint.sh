#!/bin/bash
set -e

# Database path from environment or default
DB_PATH="${DATABASE_PATH:-/app/data/debrid_stream_prod.db}"
DB_DIR=$(dirname "$DB_PATH")

echo "==> Starting Debrid Stream..."
echo "==> Database path: $DB_PATH"

# Ensure data directory exists
mkdir -p "$DB_DIR"

# Check if database exists
if [ ! -f "$DB_PATH" ]; then
    echo "==> Database does not exist. Creating database..."
    /app/bin/debrid_stream eval "VFS.Repo.start_link()" > /dev/null 2>&1 || true
    
    echo "==> Running migrations..."
    /app/bin/debrid_stream eval "
    {:ok, _} = Application.ensure_all_started(:vfs)
    path = Path.join(:code.priv_dir(:vfs), \"repo/migrations\")
    Ecto.Migrator.run(VFS.Repo, path, :up, all: true)
    "
    echo "==> Database created and migrations complete!"
else
    echo "==> Database exists. Checking for pending migrations..."
    
    # Run migrations if any are pending
    # This will run on every startup to handle updates
    /app/bin/debrid_stream eval "
    {:ok, _} = Application.ensure_all_started(:vfs)
    path = Path.join(:code.priv_dir(:vfs), \"repo/migrations\")
    
    # Check for pending migrations
    pending = Ecto.Migrator.migrations(VFS.Repo, path)
    |> Enum.filter(fn {status, _version, _name} -> status == :down end)
    
    if length(pending) > 0 do
      IO.puts(\"==> Found #{length(pending)} pending migration(s). Running migrations...\")
      Ecto.Migrator.run(VFS.Repo, path, :up, all: true)
      IO.puts(\"==> Migrations complete!\")
    else
      IO.puts(\"==> No pending migrations.\")
    end
    "
fi

echo "==> Starting application..."

# Execute the passed command (usually the release start command)
exec "$@"
