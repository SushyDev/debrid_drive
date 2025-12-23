defmodule SyncEngine.Schemas.Torrent do
  @moduledoc """
  Schema for Real Debrid torrents synchronized to the VFS.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "torrents" do
    # Real Debrid fields
    field(:rd_id, :string)
    field(:filename, :string)
    field(:hash, :string)
    # bigint in database, integer type in Ecto
    field(:bytes, :integer)
    field(:host, :string)
    field(:split, :integer)
    field(:progress, :integer)
    field(:status, :string)
    field(:added, :string)
    field(:ended, :string)
    field(:speed, :integer)
    field(:seeders, :integer)

    # Deletion tracking fields
    field(:deletion_status, :string)
    field(:deletion_requested_at, :utc_datetime)
    field(:deletion_attempts, :integer, default: 0)
    field(:deletion_last_attempted_at, :utc_datetime)
    field(:deletion_error, :string)

    # Relationships
    # Reference to the directory inode in VFS
    field(:inode_id, :integer)
    # Note: files relationship removed - query by torrent_hash instead
    # TorrentFiles now reference torrents by hash, not by ID

    timestamps()
  end

  @doc false
  def changeset(torrent, attrs) do
    torrent
    |> cast(attrs, [
      :rd_id,
      :filename,
      :hash,
      :bytes,
      :host,
      :split,
      :progress,
      :status,
      :added,
      :ended,
      :speed,
      :seeders,
      :inode_id,
      :deletion_status,
      :deletion_requested_at,
      :deletion_attempts,
      :deletion_last_attempted_at,
      :deletion_error
    ])
    |> validate_required([:rd_id, :filename, :hash, :bytes])
    |> unique_constraint(:rd_id)
    # Note: hash is NOT unique - multiple torrent instances can have the same hash
    |> foreign_key_constraint(:inode_id)
  end

  @doc """
  Creates a changeset from Real Debrid API data.
  """
  def from_rd_api(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(%{
      rd_id: attrs[:id] || attrs["id"],
      filename: attrs[:filename] || attrs["filename"],
      hash: attrs[:hash] || attrs["hash"],
      bytes: attrs[:bytes] || attrs["bytes"],
      host: attrs[:host] || attrs["host"],
      split: attrs[:split] || attrs["split"],
      progress: attrs[:progress] || attrs["progress"],
      status: attrs[:status] || attrs["status"],
      added: attrs[:added] || attrs["added"],
      ended: attrs[:ended] || attrs["ended"],
      speed: attrs[:speed] || attrs["speed"],
      seeders: attrs[:seeders] || attrs["seeders"]
    })
  end
end
