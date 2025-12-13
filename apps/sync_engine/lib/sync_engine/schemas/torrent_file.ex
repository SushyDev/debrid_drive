defmodule SyncEngine.Schemas.TorrentFile do
  @moduledoc """
  Schema for individual files within a Real Debrid torrent.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias VFS.Node
  alias SyncEngine.Schemas.Torrent

  schema "torrent_files" do
    # Real Debrid file fields
    field(:rd_id, :integer)
    field(:path, :string)
    field(:bytes, :integer)
    field(:selected, :integer)

    # Link from torrent_info (used for unrestricting)
    field(:link, :string)

    # Download link caching
    field(:download_link, :string)
    field(:link_expires_at, :utc_datetime)
    field(:link_fetched_at, :utc_datetime)

    # Virtual inode hardlink reference counting
    # Tracks how many VFS hardlink nodes point to this virtual inode
    # When count reaches 0, all user references are gone
    field(:hardlink_count, :integer, default: 1)

    # Relationships
    belongs_to(:torrent, Torrent)
    belongs_to(:node, Node)

    timestamps()
  end

  @doc false
  def changeset(torrent_file, attrs) do
    torrent_file
    |> cast(attrs, [
      :rd_id,
      :path,
      :bytes,
      :selected,
      :link,
      :torrent_id,
      :node_id,
      :download_link,
      :link_expires_at,
      :link_fetched_at,
      :hardlink_count
    ])
    |> validate_required([:rd_id, :path, :bytes, :selected, :torrent_id])
    |> validate_number(:hardlink_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:torrent_id, :rd_id])
    |> foreign_key_constraint(:torrent_id)
    |> foreign_key_constraint(:node_id)
  end

  @doc """
  Creates a changeset from Real Debrid API file data.
  """
  def from_rd_api(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(%{
      rd_id: attrs[:id] || attrs["id"],
      path: attrs[:path] || attrs["path"],
      bytes: attrs[:bytes] || attrs["bytes"],
      selected: attrs[:selected] || attrs["selected"]
    })
  end

  @doc """
  Checks if the download link is cached and not expired.
  """
  def link_valid?(%__MODULE__{download_link: nil}), do: false

  def link_valid?(%__MODULE__{link_expires_at: nil, download_link: link}) when not is_nil(link),
    do: true

  def link_valid?(%__MODULE__{link_expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end

  @doc """
  Updates the cached download link with expiration time.
  Default expiration is 4 hours from now.
  """
  def cache_link_changeset(torrent_file, link, expires_in_seconds \\ 14_400) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, expires_in_seconds, :second)

    changeset(torrent_file, %{
      download_link: link,
      link_fetched_at: now,
      link_expires_at: expires_at
    })
  end
end
