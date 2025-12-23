defmodule VFS.Repo.Migrations.AddForeignKeyCascadeToTorrentFiles do
  @moduledoc """
  Adds a database trigger to automatically delete torrent_files when their parent
  torrent is deleted, effectively implementing CASCADE DELETE behavior.

  This maintains data integrity while keeping the hash-based relationship that makes
  the system resilient to torrent re-additions.
  """
  use Ecto.Migration

  def up do
    # Add trigger to cascade delete torrent_files when torrent is deleted
    # SQLite doesn't support foreign keys on non-primary key columns easily,
    # so we use a trigger instead

    # Make idempotent - drop if exists first
    execute("DROP TRIGGER IF EXISTS delete_torrent_files_on_torrent_delete")

    execute("""
    CREATE TRIGGER delete_torrent_files_on_torrent_delete
    BEFORE DELETE ON torrents
    FOR EACH ROW
    BEGIN
      DELETE FROM torrent_files WHERE torrent_hash = OLD.hash;
    END;
    """)
  end

  def down do
    # Remove the trigger
    execute("DROP TRIGGER IF EXISTS delete_torrent_files_on_torrent_delete")
  end
end
