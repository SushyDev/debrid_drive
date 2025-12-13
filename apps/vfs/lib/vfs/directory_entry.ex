defmodule VFS.DirectoryEntry do
  @moduledoc """
  Schema for directory entries - maps names to inodes.

  A directory entry is essentially a (parent_inode_id, name) → inode_id mapping.
  This is the "directory entry" in POSIX terms. Multiple directory entries can
  point to the same inode (hardlinks).

  ## Fields

  - `parent_inode_id` - Inode ID of the parent directory
  - `name` - Entry name (filename)
  - `inode_id` - Inode ID this entry points to

  ## Constraints

  - (parent_inode_id, name) must be unique - no duplicate names in same directory
  - inode_id must reference a valid inode
  - parent_inode_id must reference a valid directory inode

  ## Examples

      # Entry for /foo/bar.txt pointing to inode 42
      %DirectoryEntry{
        parent_inode_id: 10,  # inode for /foo directory
        name: "bar.txt",
        inode_id: 42
      }
      
      # Two hardlinks to the same file (inode 42)
      %DirectoryEntry{
        parent_inode_id: 10,
        name: "bar.txt",
        inode_id: 42
      }
      
      %DirectoryEntry{
        parent_inode_id: 11,
        name: "link.txt",
        inode_id: 42  # Same inode!
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "directory_entries" do
    belongs_to(:parent, VFS.Inode, foreign_key: :parent_inode_id, references: :inode_id)
    field(:name, :string)
    belongs_to(:inode, VFS.Inode, foreign_key: :inode_id, references: :inode_id)

    timestamps()
  end

  @doc """
  Changeset for creating/updating directory entries.

  ## Required fields
  - `:parent_inode_id` - Parent directory inode ID
  - `:name` - Entry name
  - `:inode_id` - Target inode ID
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:parent_inode_id, :name, :inode_id])
    |> validate_required([:parent_inode_id, :name, :inode_id])
    |> validate_name()
    |> foreign_key_constraint(:parent_inode_id)
    |> foreign_key_constraint(:inode_id)
    |> unique_constraint([:parent_inode_id, :name])
  end

  # Validates that name is not empty and doesn't contain path separators
  defp validate_name(changeset) do
    changeset
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:name, ~r/^[^\/\0]+$/, message: "cannot contain / or null bytes")
    |> validate_exclusion(:name, [".", ".."], message: "cannot use reserved names . or ..")
  end

  @doc """
  Checks if two entries point to the same inode (are hardlinks).
  """
  def hardlink?(entry1, entry2) do
    entry1.inode_id == entry2.inode_id
  end
end
