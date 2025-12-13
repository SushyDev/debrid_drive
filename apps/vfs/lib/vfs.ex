defmodule VFS do
  @moduledoc """
  The VFS context - public API for the filesystem.

  Uses the POSIX inode system with separate inodes and directory entries.
  """

  import Ecto.Query, warn: false
  alias VFS.Repo
  alias VFS.Inode
  alias VFS.DirectoryEntry
  alias VFS.FileMode
  alias SyncEngine.Schemas.Torrent

  @doc """
  Gets the root inode (inode_id=1).
  Creates it if it doesn't exist.
  Uses a transaction to handle race conditions and retries on busy errors.
  """
  def get_root do
    get_root_with_retry(3)
  end

  defp get_root_with_retry(0), do: {:error, :too_many_retries}

  defp get_root_with_retry(attempts_left) do
    try do
      Repo.transaction(fn ->
        case Repo.get(Inode, 1) do
          nil ->
            # Root doesn't exist, create it
            case create_root() do
              {:ok, root} -> root
              {:error, changeset} -> Repo.rollback(changeset)
            end

          root ->
            root
        end
      end)
    rescue
      error in Exqlite.Error ->
        if error.message in ["database is locked", "Database busy"] and attempts_left > 1 do
          # Brief backoff before retry
          Process.sleep(10)
          get_root_with_retry(attempts_left - 1)
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  @doc """
  Creates the root directory inode.
  Root always has inode_id=1.
  """
  def create_root do
    Repo.transaction(fn ->
      # Create root inode
      {:ok, inode} =
        %Inode{}
        |> Inode.changeset(%{
          mode: FileMode.directory_mode(),
          content_type: "inode/directory",
          nlink: 1
        })
        |> Repo.insert()

      # Ensure it got inode_id=1
      if inode.inode_id != 1 do
        Repo.rollback(:root_must_be_inode_1)
      end

      inode
    end)
  end

  @doc """
  Creates a directory inode.

  ## Options
    * `:mode` - Unix permissions (default: 0o755)
  """
  def create_directory(parent_inode_id, name, opts \\ []) do
    permissions = Keyword.get(opts, :mode, 0o755)
    mode = FileMode.directory_mode(permissions)

    Repo.transaction(fn ->
      # Create inode
      {:ok, inode} =
        %Inode{}
        |> Inode.changeset(%{
          mode: mode,
          content_type: "inode/directory",
          nlink: 1
        })
        |> Repo.insert()

      # Create directory entry
      {:ok, _entry} =
        %DirectoryEntry{}
        |> DirectoryEntry.changeset(%{
          parent_inode_id: parent_inode_id,
          name: name,
          inode_id: inode.inode_id
        })
        |> Repo.insert()

      inode
    end)
  end

  @doc """
  Creates a file inode.

  ## Options
    * `:mode` - Unix permissions (default: 0o644)
    * `:data` - Initial file content
    * `:content_type` - MIME type
    * `:size` - File size (calculated from data if not provided)
  """
  def create_file(parent_inode_id, name, opts \\ []) do
    permissions = Keyword.get(opts, :mode, 0o644)
    mode = FileMode.file_mode(permissions)
    data = Keyword.get(opts, :data)
    size = Keyword.get(opts, :size, if(data, do: byte_size(data), else: 0))
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    Repo.transaction(fn ->
      # Create inode
      {:ok, inode} =
        %Inode{}
        |> Inode.changeset(%{
          mode: mode,
          data: data,
          size: size,
          content_type: content_type,
          nlink: 1
        })
        |> Repo.insert()

      # Create directory entry
      {:ok, _entry} =
        %DirectoryEntry{}
        |> DirectoryEntry.changeset(%{
          parent_inode_id: parent_inode_id,
          name: name,
          inode_id: inode.inode_id
        })
        |> Repo.insert()

      inode
    end)
  end

  @doc """
  Creates a hard link to an existing inode.

  True POSIX hardlink: creates a new directory entry pointing to the same inode
  and increments the inode's nlink count.

  Special case: If the target is a virtual inode (streamable file),
  this creates another hardlink to the same virtual inode.

  ## Parameters
    - `parent_inode_id`: Parent directory inode ID
    - `name`: Name for the new hardlink
    - `target_inode_id`: Inode ID to link to

  ## Returns
    - `{:ok, inode}` on success
    - `{:error, reason}` on failure
  """
  def create_hardlink(parent_inode_id, name, target_inode_id) do
    Repo.transaction(fn ->
      # Get target inode
      target_inode = Repo.get!(Inode, target_inode_id)

      # Create directory entry pointing to same inode
      case %DirectoryEntry{}
           |> DirectoryEntry.changeset(%{
             parent_inode_id: parent_inode_id,
             name: name,
             inode_id: target_inode.inode_id
           })
           |> Repo.insert() do
        {:ok, _entry} ->
          # Increment nlink count
          {:ok, _updated_inode} =
            target_inode
            |> Inode.increment_nlink()
            |> Repo.update()

          # If this is a virtual inode, also increment the external hardlink count
          if target_inode.virtual_inode_type == "torrent_file" do
            case SyncEngine.Torrents.get_torrent_file_by_id(target_inode.virtual_inode_id) do
              {:ok, torrent_file} ->
                case SyncEngine.Torrents.increment_hardlink_count(torrent_file) do
                  {:ok, _} -> :ok
                  error -> Repo.rollback(error)
                end

              error ->
                Repo.rollback(error)
            end
          end

          target_inode

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Looks up a child inode by name within a parent.
  Returns {:ok, inode} or {:error, :not_found}
  """
  def lookup(parent_inode_id, name) do
    result =
      from(de in DirectoryEntry,
        where: de.parent_inode_id == ^parent_inode_id and de.name == ^name,
        join: i in Inode,
        on: de.inode_id == i.inode_id,
        select: i
      )
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      inode -> {:ok, inode}
    end
  end

  @doc """
  Lists all children of a directory inode.
  Returns a list of {directory_entry, inode} tuples.
  """
  def list_children(inode_id) do
    from(de in DirectoryEntry,
      where: de.parent_inode_id == ^inode_id,
      join: i in Inode,
      on: de.inode_id == i.inode_id,
      order_by: de.name,
      select: {de, i}
    )
    |> Repo.all()
  end

  @doc """
  Gets an inode by ID.
  """
  def get_node(inode_id) do
    case Repo.get(Inode, inode_id) do
      nil -> {:error, :not_found}
      inode -> {:ok, inode}
    end
  end

  @doc """
  Gets an inode by ID, raises if not found.
  """
  def get_node!(inode_id) do
    Repo.get!(Inode, inode_id)
  end

  @doc """
  Moves/renames a directory entry.
  """
  def move(parent_inode_id, old_name, new_parent_inode_id, new_name) do
    Repo.transaction(fn ->
      # Find the directory entry
      entry =
        Repo.one!(
          from(de in DirectoryEntry,
            where: de.parent_inode_id == ^parent_inode_id and de.name == ^old_name
          )
        )

      # Update it
      entry
      |> DirectoryEntry.changeset(%{
        parent_inode_id: new_parent_inode_id,
        name: new_name
      })
      |> Repo.update!()
    end)
  end

  @doc """
  Removes a directory entry by parent_inode_id and name.

  ## Options
    * `:cascade` - When true, recursively delete directory contents (default: false)

  ## Behaviors
  - Deletes the directory entry
  - Decrements the inode's nlink count
  - If nlink reaches 0, deletes the inode
  - For virtual inodes, also decrements external hardlink count
  - Directories must be empty unless cascade: true

  ## Returns
  - `:ok` on success
  - `{:error, :not_found}` if entry doesn't exist
  - `{:error, :directory_not_empty}` if directory has children and cascade is false
  - `{:error, :cannot_delete_root}` if attempting to delete root
  """
  def remove(parent_inode_id, name, opts \\ [])

  def remove(nil = _parent_inode_id, "/" = _name, _opts) do
    {:error, :cannot_delete_root}
  end

  def remove(parent_inode_id, name, opts) do
    cascade = Keyword.get(opts, :cascade, true)

    result =
      Repo.transaction(fn ->
        # Find directory entry
        entry =
          Repo.one(
            from(de in DirectoryEntry,
              where: de.parent_inode_id == ^parent_inode_id and de.name == ^name
            )
          )

        if is_nil(entry) do
          Repo.rollback(:not_found)
        else
          # Get inode
          inode = Repo.get!(Inode, entry.inode_id)

          # If directory, check if empty
          if FileMode.dir?(inode.mode) do
            children_count =
              Repo.one(
                from(de in DirectoryEntry,
                  where: de.parent_inode_id == ^inode.inode_id,
                  select: count(de.id)
                )
              )

            if children_count > 0 and not cascade do
              Repo.rollback(:directory_not_empty)
            else
              # Recursively delete children if cascade
              if cascade and children_count > 0 do
                children = list_children(inode.inode_id)

                Enum.each(children, fn {child_entry, _child_inode} ->
                  case remove(inode.inode_id, child_entry.name, cascade: true) do
                    :ok -> :ok
                    {:error, reason} -> Repo.rollback(reason)
                  end
                end)
              end

              # Delete this directory entry and decrement nlink
              do_remove_entry(entry, inode)
            end
          else
            # Regular file - just delete entry and decrement nlink
            do_remove_entry(entry, inode)
          end
        end
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Helper to remove a directory entry and handle nlink
  defp do_remove_entry(entry, inode) do
    # Delete directory entry
    Repo.delete!(entry)

    # Decrement nlink
    new_nlink = inode.nlink - 1

    if new_nlink == 0 do
      # Last link removed - delete inode
      # If virtual inode, decrement external count first
      if inode.virtual_inode_type == "torrent_file" do
        case SyncEngine.Torrents.get_torrent_file_by_id(inode.virtual_inode_id) do
          {:ok, torrent_file} ->
            SyncEngine.Torrents.decrement_hardlink_count(torrent_file)

          _ ->
            :ok
        end
      end

      Repo.delete!(inode)
    else
      # Update nlink count
      inode
      |> Inode.changeset(%{nlink: new_nlink})
      |> Repo.update!()

      # If virtual inode, decrement external count
      if inode.virtual_inode_type == "torrent_file" do
        case SyncEngine.Torrents.get_torrent_file_by_id(inode.virtual_inode_id) do
          {:ok, torrent_file} ->
            SyncEngine.Torrents.decrement_hardlink_count(torrent_file)

          _ ->
            :ok
        end
      end
    end

    :ok
  end

  @doc """
  Removes an inode by ID (legacy compatibility).
  """
  def remove_by_id(inode_id, opts \\ []) do
    # Find any directory entry pointing to this inode
    entry =
      Repo.one(
        from(de in DirectoryEntry,
          where: de.inode_id == ^inode_id,
          limit: 1
        )
      )

    case entry do
      nil -> {:error, :not_found}
      entry -> remove(entry.parent_inode_id, entry.name, opts)
    end
  end

  @doc """
  Counts the number of hard links to an inode.
  Simply returns the nlink field.
  """
  def count_hardlinks_to_target(inode_id) do
    case Repo.get(Inode, inode_id) do
      nil -> 0
      inode -> inode.nlink
    end
  end

  @doc """
  Finds all directory entries pointing to an inode.
  Returns a list of {directory_entry, parent_inode} tuples.
  """
  def find_all_hardlinks_to_target(inode_id) do
    from(de in DirectoryEntry,
      where: de.inode_id == ^inode_id,
      join: parent in Inode,
      on: de.parent_inode_id == parent.inode_id,
      order_by: de.name,
      select: {de, parent}
    )
    |> Repo.all()
  end

  @doc """
  Updates the data and size of an inode.
  """
  def write_data(inode_id, data, offset \\ 0) do
    inode = Repo.get!(Inode, inode_id)

    new_data =
      case offset do
        0 ->
          data

        _ ->
          existing = inode.data || <<>>
          # Pad with zeros if offset is beyond current data
          padded =
            if byte_size(existing) < offset do
              existing <> :binary.copy(<<0>>, offset - byte_size(existing))
            else
              existing
            end

          # Replace data at offset
          <<before::binary-size(offset), _::binary>> = padded
          before <> data
      end

    inode
    |> Inode.changeset(%{
      data: new_data,
      size: byte_size(new_data)
    })
    |> Repo.update()
  end

  @doc """
  Reads data from an inode with optional offset and size.
  """
  def read_data(inode_id, offset \\ 0, size \\ nil) do
    case get_node(inode_id) do
      {:ok, inode} ->
        data = inode.data || <<>>

        result =
          if offset >= byte_size(data) do
            <<>>
          else
            case size do
              nil -> binary_part(data, offset, byte_size(data) - offset)
              s when offset + s <= byte_size(data) -> binary_part(data, offset, s)
              s -> binary_part(data, offset, min(s, byte_size(data) - offset))
            end
          end

        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Updates inode attributes.
  """
  def update_node(inode_id, attrs) do
    inode = Repo.get!(Inode, inode_id)

    inode
    |> Inode.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Creates a hardlink to a virtual inode (torrent file).

  Virtual inodes are backed by torrent_files records instead of regular file data.

  ## Parameters
    - `parent_inode_id`: Parent directory inode ID
    - `name`: Name of the hardlink
    - `virtual_inode_id`: ID of the torrent_file
    - `opts`: Options including :size for file size

  ## Returns
    - `{:ok, inode}` on success
    - `{:error, reason}` on failure
  """
  def create_hardlink_to_virtual_inode(parent_inode_id, name, virtual_inode_id, opts \\ []) do
    size = Keyword.get(opts, :size, 0)

    Repo.transaction(fn ->
      # Check if virtual inode already exists
      existing_inode =
        Repo.one(
          from(i in Inode,
            where:
              i.virtual_inode_type == "torrent_file" and i.virtual_inode_id == ^virtual_inode_id,
            limit: 1
          )
        )

      inode =
        case existing_inode do
          nil ->
            # Create new virtual inode
            {:ok, new_inode} =
              %Inode{}
              |> Inode.changeset(%{
                mode: FileMode.file_mode(),
                size: size,
                nlink: 1,
                virtual_inode_type: "torrent_file",
                virtual_inode_id: virtual_inode_id
              })
              |> Repo.insert()

            # Increment the external hardlink count on the torrent_file
            case SyncEngine.Torrents.get_torrent_file_by_id(virtual_inode_id) do
              {:ok, torrent_file} ->
                case SyncEngine.Torrents.increment_hardlink_count(torrent_file) do
                  {:ok, _} -> :ok
                  error -> Repo.rollback(error)
                end

              error ->
                Repo.rollback(error)
            end

            new_inode

          inode ->
            # Increment nlink on existing virtual inode
            {:ok, updated} =
              inode
              |> Inode.increment_nlink()
              |> Repo.update()

            # Also increment the external hardlink count on the torrent_file
            case SyncEngine.Torrents.get_torrent_file_by_id(virtual_inode_id) do
              {:ok, torrent_file} ->
                case SyncEngine.Torrents.increment_hardlink_count(torrent_file) do
                  {:ok, _} -> :ok
                  error -> Repo.rollback(error)
                end

              error ->
                Repo.rollback(error)
            end

            updated
        end

      # Create directory entry
      {:ok, _entry} =
        %DirectoryEntry{}
        |> DirectoryEntry.changeset(%{
          parent_inode_id: parent_inode_id,
          name: name,
          inode_id: inode.inode_id
        })
        |> Repo.insert()

      inode
    end)
  end

  @doc """
  Counts hardlinks pointing to a virtual inode.
  """
  def count_hardlinks_to_virtual_inode(virtual_inode_id) do
    case Repo.one(
           from(i in Inode,
             where:
               i.virtual_inode_type == "torrent_file" and i.virtual_inode_id == ^virtual_inode_id,
             select: i.nlink
           )
         ) do
      nil -> 0
      nlink -> nlink
    end
  end

  @doc """
  Finds all directory entries pointing to a virtual inode.
  """
  def find_all_hardlinks_to_virtual_inode(virtual_inode_id) do
    inode =
      Repo.one(
        from(i in Inode,
          where:
            i.virtual_inode_type == "torrent_file" and i.virtual_inode_id == ^virtual_inode_id
        )
      )

    case inode do
      nil ->
        []

      inode ->
        from(de in DirectoryEntry,
          where: de.inode_id == ^inode.inode_id,
          order_by: de.name
        )
        |> Repo.all()
    end
  end

  @doc """
  Checks if an inode is a virtual inode.
  Returns true if it has virtual_inode_type and virtual_inode_id.
  """
  def is_hardlink?(inode) do
    # In the new schema, all files with nlink > 1 are hardlinks
    # But we keep this for compatibility - virtual inodes are identified by virtual_inode_type
    not is_nil(inode.virtual_inode_type) && not is_nil(inode.virtual_inode_id)
  end

  @doc """
  Extracts the virtual inode ID from an inode.

  Returns:
  - `{:ok, virtual_inode_id}` if it's a virtual inode
  - `{:error, :not_virtual_inode}` if it's a regular inode
  """
  def extract_virtual_inode_id(inode) when is_map(inode) do
    if inode.virtual_inode_type == "torrent_file" and inode.virtual_inode_id do
      {:ok, inode.virtual_inode_id}
    else
      {:error, :not_virtual_inode}
    end
  end

  def extract_virtual_inode_id(_), do: {:error, :not_virtual_inode}
end
