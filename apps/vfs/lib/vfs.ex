defmodule VFS do
  @moduledoc """
  The VFS context - public API for the filesystem.

  Uses the POSIX inode system with separate inodes and directory entries.
  """

  require Logger
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
  Returns {:ok, inode} or {:error, reason}.
  """
  def create_root do
    # Explicitly insert root inode with inode_id=1
    # We set inode_id directly to ensure it's 1, not relying on autoincrement
    changeset =
      %Inode{inode_id: 1}
      |> Inode.changeset(%{
        mode: FileMode.directory_mode(),
        content_type: "inode/directory",
        nlink: 1
      })

    case Repo.insert(changeset) do
      {:ok, inode} ->
        # Successfully created root with inode_id=1
        Logger.debug("Created root inode with inode_id=1")
        {:ok, inode}

      {:error, changeset} ->
        # Insert failed - could be a race condition where another process created root
        # Check if root now exists
        case Repo.get(Inode, 1) do
          nil ->
            # Root still doesn't exist, this is a real error
            Logger.error("Failed to create root inode: #{inspect(changeset)}")
            {:error, changeset}

          root ->
            # Root exists now (created by another process), return it
            Logger.debug("Root inode already exists (race condition), returning it")
            {:ok, root}
        end
    end
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
          # If this is a virtual inode, validate the external torrent_file exists first
          # This prevents creating a directory entry to a broken virtual inode
          if target_inode.virtual_inode_type == "torrent_file" do
            case SyncEngine.Torrents.get_torrent_file_by_id(target_inode.virtual_inode_id) do
              {:ok, _torrent_file} ->
                :ok

              error ->
                Logger.error("Cannot create hardlink: torrent_file #{target_inode.virtual_inode_id} not found")

                Repo.rollback(error)
            end
          end

          # Increment nlink count
          {:ok, updated_inode} =
            target_inode
            |> Inode.increment_nlink()
            |> Repo.update()

          # If this is a virtual inode, increment the external hardlink count
          # Note: This is done after nlink increment, but both are within a transaction
          # so if the external increment fails, the entire transaction (including nlink) rolls back
          if target_inode.virtual_inode_type == "torrent_file" do
            case SyncEngine.Torrents.get_torrent_file_by_id(target_inode.virtual_inode_id) do
              {:ok, torrent_file} ->
                case SyncEngine.Torrents.increment_hardlink_count(torrent_file) do
                  {:ok, _} ->
                    :ok

                  {:error, reason} = error ->
                    Logger.error("Failed to increment external hardlink count for torrent_file #{target_inode.virtual_inode_id}: #{inspect(reason)}")

                    Repo.rollback(error)
                end

              error ->
                Repo.rollback(error)
            end
          end

          updated_inode

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
      DirectoryEntry
      |> where([directory_entry], directory_entry.parent_inode_id == ^parent_inode_id)
      |> where([directory_entry], directory_entry.name == ^name)
      |> join(:inner, [directory_entry], inode in Inode, on: directory_entry.inode_id == inode.inode_id)
      |> select([_directory_entry, inode], inode)
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
    DirectoryEntry
    |> where([directory_entry], directory_entry.parent_inode_id == ^inode_id)
    |> join(:inner, [directory_entry], inode in Inode, on: directory_entry.inode_id == inode.inode_id)
    |> order_by([directory_entry], directory_entry.name)
    |> select([directory_entry, inode], {directory_entry, inode})
    |> Repo.all()
  end

  @doc """
  Gets an inode by ID.

  Note: This function is also available as `get_node/1` for backward compatibility,
  but "node" is legacy terminology from the old schema. Use `get_inode/1` in new code.

  Returns `{:ok, inode}` or `{:error, :not_found}`.
  """
  def get_inode(inode_id) do
    case Repo.get(Inode, inode_id) do
      nil -> {:error, :not_found}
      inode -> {:ok, inode}
    end
  end

  @doc """
  Gets an inode by ID (legacy name).

  **Deprecated**: Use `get_inode/1` instead. This function exists for backward
  compatibility but "node" refers to the old schema terminology.
  """
  def get_node(inode_id), do: get_inode(inode_id)

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
        DirectoryEntry
        |> where([directory_entry], directory_entry.parent_inode_id == ^parent_inode_id)
        |> where([directory_entry], directory_entry.name == ^old_name)
        |> Repo.one!()

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
          DirectoryEntry
          |> where([directory_entry], directory_entry.parent_inode_id == ^parent_inode_id)
          |> where([directory_entry], directory_entry.name == ^name)
          |> Repo.one()

        if is_nil(entry) do
          Repo.rollback(:not_found)
        else
          # Get inode
          inode = Repo.get!(Inode, entry.inode_id)

          # If directory, check if empty
          if FileMode.dir?(inode.mode) do
            children_count =
              DirectoryEntry
              |> where([directory_entry], directory_entry.parent_inode_id == ^inode.inode_id)
              |> select([directory_entry], count(directory_entry.id))
              |> Repo.one()

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

          {:error, :not_found} ->
            Logger.warning("Torrent file #{inode.virtual_inode_id} not found when removing last hardlink to inode #{inode.inode_id}")

          {:error, reason} ->
            Logger.warning("Failed to get torrent_file #{inode.virtual_inode_id} for hardlink count decrement: #{inspect(reason)}")
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

          {:error, :not_found} ->
            Logger.warning("Torrent file #{inode.virtual_inode_id} not found when removing hardlink to inode #{inode.inode_id}")

          {:error, reason} ->
            Logger.warning("Failed to get torrent_file #{inode.virtual_inode_id} for hardlink count decrement: #{inspect(reason)}")
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
      DirectoryEntry
      |> where([directory_entry], directory_entry.inode_id == ^inode_id)
      |> limit(1)
      |> Repo.one()

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
    DirectoryEntry
    |> where([directory_entry], directory_entry.inode_id == ^inode_id)
    |> join(:inner, [directory_entry], parent in Inode, on: directory_entry.parent_inode_id == parent.inode_id)
    |> order_by([directory_entry], directory_entry.name)
    |> select([directory_entry, parent], {directory_entry, parent})
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
      # Note: SQLite doesn't support row-level locking (FOR UPDATE), so we rely on
      # the unique constraint to handle concurrent creation attempts gracefully
      existing_inode =
        Inode
        |> where([inode], inode.virtual_inode_type == "torrent_file")
        |> where([inode], inode.virtual_inode_id == ^virtual_inode_id)
        |> limit(1)
        |> Repo.one()

      inode =
        case existing_inode do
          nil ->
            # Create new virtual inode
            # Note: The unique constraint will still catch any race condition,
            # but we handle it gracefully by retrying the lookup
            case %Inode{}
                 |> Inode.changeset(%{
                   mode: FileMode.file_mode(),
                   size: size,
                   nlink: 1,
                   virtual_inode_type: "torrent_file",
                   virtual_inode_id: virtual_inode_id
                 })
                 |> Repo.insert() do
              {:ok, new_inode} ->
                Logger.debug("Created new virtual inode #{new_inode.inode_id} for torrent_file #{virtual_inode_id}")

                # Increment the external hardlink count on the torrent_file
                case SyncEngine.Torrents.get_torrent_file_by_id(virtual_inode_id) do
                  {:ok, torrent_file} ->
                    case SyncEngine.Torrents.increment_hardlink_count(torrent_file) do
                      {:ok, _} ->
                        :ok

                      {:error, reason} = error ->
                        Logger.error("Failed to increment hardlink count for torrent_file #{virtual_inode_id}: #{inspect(reason)}")

                        Repo.rollback(error)
                    end

                  {:error, reason} = error ->
                    Logger.error("Torrent file #{virtual_inode_id} not found when creating virtual inode hardlink: #{inspect(reason)}")

                    Repo.rollback(error)
                end

                new_inode

              {:error, %{errors: errors} = changeset} ->
                # Check if this is a unique constraint violation
                if Keyword.has_key?(errors, :virtual_inode_id) or
                     Keyword.has_key?(errors, :virtual_inode_type) do
                  # Race condition occurred - another transaction created the inode
                  # Retry the lookup (without lock since SQLite doesn't support FOR UPDATE)
                  Logger.debug("Detected concurrent creation of virtual inode for torrent_file #{virtual_inode_id}, retrying lookup")

                  case Inode
                       |> where([inode], inode.virtual_inode_type == "torrent_file")
                       |> where([inode], inode.virtual_inode_id == ^virtual_inode_id)
                       |> limit(1)
                       |> Repo.one() do
                    nil ->
                      # Still doesn't exist - this shouldn't happen
                      Logger.error("Virtual inode still not found after constraint violation for torrent_file #{virtual_inode_id}")

                      Repo.rollback({:error, :virtual_inode_not_found_after_conflict})

                    found_inode ->
                      # Found it - increment nlink
                      {:ok, updated} =
                        found_inode
                        |> Inode.increment_nlink()
                        |> Repo.update()

                      Logger.debug("Incremented nlink to #{updated.nlink} for virtual inode #{updated.inode_id} (after race condition resolution)")

                      # Also increment the external hardlink count on the torrent_file
                      case SyncEngine.Torrents.get_torrent_file_by_id(virtual_inode_id) do
                        {:ok, torrent_file} ->
                          case SyncEngine.Torrents.increment_hardlink_count(torrent_file) do
                            {:ok, _} ->
                              :ok

                            {:error, reason} = error ->
                              Logger.error("Failed to increment hardlink count for torrent_file #{virtual_inode_id}: #{inspect(reason)}")

                              Repo.rollback(error)
                          end

                        {:error, reason} = error ->
                          Logger.error("Torrent file #{virtual_inode_id} not found when creating virtual inode hardlink: #{inspect(reason)}")

                          Repo.rollback(error)
                      end

                      updated
                  end
                else
                  # Some other error
                  Logger.error("Failed to create virtual inode for torrent_file #{virtual_inode_id}: #{inspect(changeset)}")

                  Repo.rollback({:error, changeset})
                end
            end

          inode ->
            # Increment nlink on existing virtual inode
            {:ok, updated} =
              inode
              |> Inode.increment_nlink()
              |> Repo.update()

            Logger.debug("Incremented nlink to #{updated.nlink} for virtual inode #{updated.inode_id}")

            # Also increment the external hardlink count on the torrent_file
            case SyncEngine.Torrents.get_torrent_file_by_id(virtual_inode_id) do
              {:ok, torrent_file} ->
                case SyncEngine.Torrents.increment_hardlink_count(torrent_file) do
                  {:ok, _} ->
                    :ok

                  {:error, reason} = error ->
                    Logger.error("Failed to increment hardlink count for torrent_file #{virtual_inode_id}: #{inspect(reason)}")

                    Repo.rollback(error)
                end

              {:error, reason} = error ->
                Logger.error("Torrent file #{virtual_inode_id} not found when creating virtual inode hardlink: #{inspect(reason)}")

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
    case Inode
         |> where([inode], inode.virtual_inode_type == "torrent_file")
         |> where([inode], inode.virtual_inode_id == ^virtual_inode_id)
         |> select([inode], inode.nlink)
         |> Repo.one() do
      nil -> 0
      nlink -> nlink
    end
  end

  @doc """
  Finds all directory entries pointing to a virtual inode.
  """
  def find_all_hardlinks_to_virtual_inode(virtual_inode_id) do
    inode =
      Inode
      |> where([inode], inode.virtual_inode_type == "torrent_file")
      |> where([inode], inode.virtual_inode_id == ^virtual_inode_id)
      |> Repo.one()

    case inode do
      nil ->
        []

      inode ->
        DirectoryEntry
        |> where([directory_entry], directory_entry.inode_id == ^inode.inode_id)
        |> order_by([directory_entry], directory_entry.name)
        |> Repo.all()
    end
  end

  @doc """
  @doc \"""
  Checks if an inode is a virtual inode (backed by external storage like RealDebrid).

  Virtual inodes are identified by having both `virtual_inode_type` and `virtual_inode_id` set.
  These represent streamable files that don't store data in the database.

  Returns `true` if it's a virtual inode, `false` otherwise.
  """
  def is_virtual_inode?(inode) do
    not is_nil(inode.virtual_inode_type) && not is_nil(inode.virtual_inode_id)
  end

  @doc """
  Checks if an inode is a virtual inode (legacy name).

  **Deprecated**: Use `is_virtual_inode?/1` instead. The name `is_hardlink?` is
  misleading because in POSIX terms, a "hardlink" is any directory entry pointing
  to an inode, and an inode can have multiple hardlinks (nlink > 1). This function
  specifically checks for virtual inodes (streamable files from RealDebrid).
  """
  def is_hardlink?(inode), do: is_virtual_inode?(inode)

  @doc """
  Checks if an inode has multiple hardlinks (POSIX semantics).

  Returns `true` if the inode has more than one directory entry pointing to it (nlink > 1).
  """
  def has_hardlinks?(inode) do
    inode.nlink > 1
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
