defmodule VFS.Repo.Migrations.RenameTorrentFieldsForClarity do
  use Ecto.Migration

  def change do
    # Rename torrents table columns for clarity
    rename(table(:torrents), :rd_id, to: :real_debrid_torrent_id)
    rename(table(:torrents), :hash, to: :real_debrid_torrent_hash)

    # Rename torrent_files table columns for clarity
    rename(table(:torrent_files), :rd_id, to: :real_debrid_torrent_file_id)
    rename(table(:torrent_files), :torrent_hash, to: :real_debrid_torrent_hash)
    rename(table(:torrent_files), :torrent_rd_id, to: :real_debrid_torrent_id)

    # Rename rejected_torrents table columns for clarity
    rename(table(:rejected_torrents), :rd_id, to: :real_debrid_torrent_id)
    rename(table(:rejected_torrents), :hash, to: :real_debrid_torrent_hash)
  end
end
