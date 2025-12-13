defmodule VFS.Inode do
  @moduledoc """
  Schema for inodes - stores file metadata (the "inode" in POSIX terms).

  An inode represents the actual file data and metadata, separate from its
  name(s) in the directory structure. Multiple directory entries can point
  to the same inode (hardlinks).

  ## Fields

  - `inode_id` - Unique inode identifier (primary key)
  - `mode` - Unix file mode (permissions + type)
  - `size` - File size in bytes
  - `data` - File content (for small files stored in database)
  - `content_type` - MIME type
  - `nlink` - Number of hard links (directory entries) pointing to this inode
  - `virtual_inode_type` - Type of virtual inode (e.g. "torrent_file" for RealDebrid)
  - `virtual_inode_id` - ID of the virtual inode (e.g. torrent_file.id)

  ## Virtual Inodes

  Virtual inodes represent files that are not stored in the database but are
  accessible remotely (e.g. streamable files from RealDebrid). They are
  identified by `virtual_inode_type` and `virtual_inode_id`.

  ## Examples

      # Regular file inode
      %Inode{
        inode_id: 42,
        mode: 33188,  # 0o100644 = -rw-r--r--
        size: 1024,
        nlink: 1,
        data: <<...>>
      }
      
      # Virtual inode (streamable file from RealDebrid)
      %Inode{
        inode_id: 100,
        mode: 33188,
        size: 60_000_000_000,  # 60 GB
        nlink: 2,  # Two hardlinks to this file
        virtual_inode_type: "torrent_file",
        virtual_inode_id: 2198
      }
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias VFS.FileMode

  @primary_key {:inode_id, :id, autogenerate: true}
  schema "inodes" do
    field(:mode, :integer)
    field(:size, :integer, default: 0)
    field(:data, :binary)
    field(:content_type, :string)
    field(:nlink, :integer, default: 1)

    # Virtual inode support
    field(:virtual_inode_type, :string)
    field(:virtual_inode_id, :integer)

    has_many(:directory_entries, VFS.DirectoryEntry, foreign_key: :inode_id)

    timestamps()
  end

  @doc """
  Changeset for creating/updating inodes.

  ## Required fields
  - `:mode` - Unix file mode

  ## Optional fields
  - `:size` - File size (default: 0)
  - `:data` - File content
  - `:content_type` - MIME type
  - `:nlink` - Number of hard links (default: 1)
  - `:virtual_inode_type` - Virtual inode type
  - `:virtual_inode_id` - Virtual inode ID
  """
  def changeset(inode, attrs) do
    inode
    |> cast(attrs, [
      :mode,
      :size,
      :data,
      :content_type,
      :nlink,
      :virtual_inode_type,
      :virtual_inode_id
    ])
    |> validate_required([:mode])
    |> validate_size()
    |> validate_mode()
    |> validate_nlink()
    |> validate_virtual_inode()
  end

  # Validates that size is non-negative
  defp validate_size(changeset) do
    validate_number(changeset, :size, greater_than_or_equal_to: 0)
  end

  # Validates that mode is a valid Unix mode
  defp validate_mode(changeset) do
    validate_number(changeset, :mode, greater_than: 0, less_than: 0o170000)
  end

  # Validates that nlink is positive
  defp validate_nlink(changeset) do
    validate_number(changeset, :nlink, greater_than: 0)
  end

  # Validates virtual inode fields
  defp validate_virtual_inode(changeset) do
    type = get_field(changeset, :virtual_inode_type)
    id = get_field(changeset, :virtual_inode_id)

    cond do
      # Both present - valid
      type && id ->
        changeset

      # Both absent - valid
      is_nil(type) && is_nil(id) ->
        changeset

      # One present, one absent - invalid
      type && is_nil(id) ->
        add_error(changeset, :virtual_inode_id, "must be present when virtual_inode_type is set")

      is_nil(type) && id ->
        add_error(changeset, :virtual_inode_type, "must be present when virtual_inode_id is set")
    end
  end

  @doc """
  Returns true if this is a virtual inode (remote file).
  """
  def virtual?(inode) do
    not is_nil(inode.virtual_inode_type) && not is_nil(inode.virtual_inode_id)
  end

  @doc """
  Returns true if this is a directory inode.
  """
  def directory?(inode) do
    FileMode.dir?(inode.mode)
  end

  @doc """
  Returns true if this is a regular file inode.
  """
  def file?(inode) do
    FileMode.file?(inode.mode)
  end

  @doc """
  Increments the nlink count for this inode.
  Used when creating a new hard link.
  """
  def increment_nlink(inode) do
    changeset(inode, %{nlink: inode.nlink + 1})
  end

  @doc """
  Decrements the nlink count for this inode.
  Used when removing a hard link.
  Returns error if nlink would become 0 or negative.
  """
  def decrement_nlink(inode) do
    new_nlink = inode.nlink - 1

    if new_nlink >= 0 do
      changeset(inode, %{nlink: new_nlink})
    else
      inode
      |> changeset(%{})
      |> add_error(:nlink, "cannot be less than 0")
    end
  end
end
