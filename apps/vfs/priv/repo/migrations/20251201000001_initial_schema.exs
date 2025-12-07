defmodule VFS.Repo.Migrations.InitialSchema do
  use Ecto.Migration

  def change do
    # VFS Nodes table - base filesystem structure
    create table(:nodes) do
      add(:parent_id, references(:nodes, on_delete: :delete_all), null: true)
      add(:name, :string, null: false)
      add(:mode, :integer, null: false)
      add(:content_type, :string)
      add(:size, :integer, default: 0)
      add(:data, :binary)

      timestamps()
    end

    create(index(:nodes, [:parent_id]))
    create(unique_index(:nodes, [:parent_id, :name]))

    # Torrents table - tracked torrents from Real Debrid
    # Note: node_id uses :restrict to allow detecting orphaned records
    create table(:torrents) do
      # Real Debrid torrent fields
      add(:rd_id, :string, null: false)
      add(:filename, :string, null: false)
      add(:hash, :string, null: false)
      add(:bytes, :bigint, null: false)
      add(:host, :string)
      add(:split, :integer)
      add(:progress, :integer)
      add(:status, :string)
      add(:added, :string)
      add(:ended, :string)
      add(:speed, :integer)
      add(:seeders, :integer)

      # Deletion tracking fields
      add(:deletion_status, :string)
      add(:deletion_requested_at, :utc_datetime)
      add(:deletion_attempts, :integer, default: 0)
      add(:deletion_last_attempted_at, :utc_datetime)
      add(:deletion_error, :text)

      # Reference to the VFS node (directory entry for this torrent)
      # Using :restrict so we can detect when VFS nodes go missing
      add(:node_id, references(:nodes, on_delete: :restrict), null: false)

      timestamps()
    end

    create(unique_index(:torrents, [:rd_id]))
    create(unique_index(:torrents, [:hash]))
    create(index(:torrents, [:node_id]))
    create(index(:torrents, [:deletion_status]))

    # Torrent files table - individual files within torrents
    create table(:torrent_files) do
      # Real Debrid file fields
      add(:rd_id, :integer, null: false)
      add(:path, :string, null: false)
      add(:bytes, :bigint, null: false)
      add(:selected, :integer, null: false)

      # Link from torrent_info (used for unrestricting)
      add(:link, :text)

      # Download link caching
      add(:download_link, :text)
      add(:link_expires_at, :utc_datetime)
      add(:link_fetched_at, :utc_datetime)

      # References
      # torrent_id uses :delete_all - when torrent is deleted, remove all files
      add(:torrent_id, references(:torrents, on_delete: :delete_all), null: false)
      # node_id uses :restrict - detect when VFS nodes go missing
      add(:node_id, references(:nodes, on_delete: :restrict), null: false)

      timestamps()
    end

    create(index(:torrent_files, [:torrent_id]))
    create(index(:torrent_files, [:node_id]))
    create(unique_index(:torrent_files, [:torrent_id, :rd_id]))
    create(index(:torrent_files, [:link_expires_at]))

    # Rejected torrents table - track torrents that failed validation
    create table(:rejected_torrents) do
      # Real Debrid torrent identification
      add(:rd_id, :string, null: false)
      add(:filename, :string, null: false)
      add(:hash, :string)

      # Rejection details
      add(:reason, :text)
      add(:error_details, :text)
      add(:attempt_count, :integer, default: 1)
      add(:last_attempted_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:rejected_torrents, [:rd_id]))
    create(index(:rejected_torrents, [:hash]))
    create(index(:rejected_torrents, [:last_attempted_at]))
  end
end
