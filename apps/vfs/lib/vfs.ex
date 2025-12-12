defmodule VFS do
  @moduledoc """
  The VFS context - public API for the filesystem.
  """

  import Ecto.Query, warn: false
  alias VFS.Repo
  alias VFS.Node
  alias VFS.FileMode

  @doc """
  Gets the root node (where parent_id is nil).
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
        case Repo.one(from(node in Node, where: is_nil(node.parent_id), limit: 1)) do
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
  Creates the root directory node.
  """
  def create_root do
    %Node{}
    |> Node.changeset(%{
      name: "/",
      mode: FileMode.directory_mode(),
      parent_id: nil
    })
    |> Repo.insert()
  end

  @doc """
  Creates a directory node.

  ## Options
    * `:mode` - Unix permissions (default: 0o755)
  """
  def create_directory(parent_id, name, opts \\ []) do
    permissions = Keyword.get(opts, :mode, 0o755)
    mode = FileMode.directory_mode(permissions)

    %Node{}
    |> Node.changeset(%{
      parent_id: parent_id,
      name: name,
      mode: mode,
      content_type: "inode/directory"
    })
    |> Repo.insert()
  end

  @doc """
  Creates a file node.

  ## Options
    * `:mode` - Unix permissions (default: 0o644)
    * `:data` - Initial file content
    * `:content_type` - MIME type
    * `:size` - File size (calculated from data if not provided)
  """
  def create_file(parent_id, name, opts \\ []) do
    permissions = Keyword.get(opts, :mode, 0o644)
    mode = FileMode.file_mode(permissions)
    data = Keyword.get(opts, :data)
    size = Keyword.get(opts, :size, if(data, do: byte_size(data), else: 0))
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    %Node{}
    |> Node.changeset(%{
      parent_id: parent_id,
      name: name,
      mode: mode,
      data: data,
      size: size,
      content_type: content_type
    })
    |> Repo.insert()
  end

  @doc """
   Creates a hard link to an existing node.

   The link appears as a regular file with the same mode and metadata as the target.
   Sets the is_hardlink flag to true and stores the target node ID in hardlink_target_node_id.

  Note: This is not a true hard link (multiple directory entries to same inode),
  but provides equivalent semantics for read-only access.
  """
  def create_hardlink(parent_id, name, target_node_id) do
    with {:ok, target_node} <- get_node(target_node_id) do
      case is_hardlink?(target_node) do
        true ->
          {:error, :cannot_link_to_hardlink}

        false ->
          # Create a node that looks identical to the target but stores a reference
          %Node{}
          |> Node.changeset(%{
            parent_id: parent_id,
            name: name,
            mode: target_node.mode,
            data: to_string(target_node_id),
            size: target_node.size,
            is_hardlink: true,
            hardlink_target_node_id: target_node_id
          })
          |> Repo.insert()
      end
    end
  end

  @doc """
  Looks up a child node by name within a parent.
  Returns {:ok, node} or {:error, :not_found}
  """
  def lookup(parent_id, name) do
    query =
      case parent_id do
        nil -> from(node in Node, where: is_nil(node.parent_id) and node.name == ^name)
        value -> from(node in Node, where: node.parent_id == ^value and node.name == ^name)
      end

    case Repo.one(query) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  @doc """
  Lists all children of a node.
  """
  def list_children(node_id) do
    Repo.all(from(node in Node, where: node.parent_id == ^node_id, order_by: node.name))
  end

  @doc """
  Gets a node by ID.
  """
  def get_node(id) do
    case Repo.get(Node, id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  @doc """
  Gets a node by ID, raises if not found.
  """
  def get_node!(id) do
    Repo.get!(Node, id)
  end

  @doc """
  Moves a node to a new parent and/or renames it.
  """
  def move(node_id, new_parent_id, new_name) do
    node = Repo.get!(Node, node_id)

    node
    |> Node.changeset(%{
      parent_id: new_parent_id,
      name: new_name
    })
    |> Repo.update()
  end

  @doc """
  Removes a node by parent_id and name.

  ## Options
    * `:cascade` - When true, recursively delete directory contents (default: false)
    * `:cascade_hardlinks` - When true, delete hard link target and all its links (default: false)

  ## Behaviors
  - Regular files: Deleted immediately
  - Hard links: Only the link is deleted, target remains (unless cascade_hardlinks: true)
  - Directories: Must be empty (unless cascade: true)
  - With cascade_hardlinks: Deletes target node and all hard links pointing to it

  ## Returns
  - `:ok` on success
  - `{:error, :not_found}` if node doesn't exist
  - `{:error, :directory_not_empty}` if directory has children and cascade is false
  - `{:error, :cannot_delete_root}` if attempting to delete the root node
  """
  def remove(parent_id, name, opts \\ [])

  def remove(nil = _parent_id, "/" = _name, _opts) do
    {:error, :cannot_delete_root}
  end

  def remove(parent_id, name, opts) do
    cascade = Keyword.get(opts, :cascade, true)
    cascade_hardlinks = Keyword.get(opts, :cascade_hardlinks, false)

    result =
      Repo.transaction(fn ->
        case lookup(parent_id, name) do
          {:error, reason} -> Repo.rollback(reason)
          {:ok, node} -> do_remove(node, cascade: cascade, cascade_hardlinks: cascade_hardlinks)
        end
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a node by ID.
  This will cascade delete children if the database is configured for it.
  Returns :ok on success or error tuple.
  """
  def remove_by_id(node_id, opts \\ []) do
    node = Repo.get!(Node, node_id)
    result = do_remove(node, opts)
    # do_remove returns deleted struct on success or error tuple on failure
    if is_struct(result), do: :ok, else: result
  end

  @doc """
  Removes a node by parent_id and name (legacy function).
  """
  def remove_by_name(parent_id, name, opts \\ []) do
    case lookup(parent_id, name) do
      {:ok, node} ->
        result = do_remove(node, opts)
        if is_struct(result), do: :ok, else: result

      error ->
        error
    end
  end

  # Private helper for removal logic
  defp do_remove(node, opts) do
    cascade = Keyword.get(opts, :cascade, true)
    cascade_hardlinks = Keyword.get(opts, :cascade_hardlinks, false)

    cond do
      # Handle virtual inode hardlink with cascade_hardlinks
      is_hardlink?(node) and cascade_hardlinks ->
        case extract_virtual_inode_id(node) do
          {:ok, _inode_id} ->
            # Virtual inode hardlink - just delete this hardlink
            # The actual virtual inode cleanup is handled by SyncEngine.Torrents
            Repo.delete!(node)

          {:error, _} ->
            # Regular POSIX hardlink - delete with target cascade
            target_id = node.hardlink_target_node_id

            case get_node(target_id) do
              {:ok, target_node} ->
                # Find all hard links pointing to this target
                hardlinks = find_all_hardlinks_to_target(target_id)
                # Delete all hard links (including this one)
                Enum.each(hardlinks, fn link -> Repo.delete!(link) end)
                # Then delete the target
                Repo.delete!(target_node)

              {:error, :not_found} ->
                # Target already deleted, just delete this orphaned link
                Repo.delete!(node)
            end
        end

      # Handle regular hard link (just delete the link)
      is_hardlink?(node) ->
        Repo.delete!(node)

      # Handle directory
      FileMode.dir?(node.mode) ->
        children = list_children(node.id)

        if length(children) > 0 and not cascade do
          Repo.rollback(:directory_not_empty)
        else
          # Recursively delete children if cascade is true
          if cascade do
            Enum.each(children, fn child ->
              do_remove(child, cascade: true, cascade_hardlinks: cascade_hardlinks)
            end)
          end

          # Before deleting the directory, check if cascade_hardlinks is set
          # and delete any hard links pointing to files within
          if cascade_hardlinks do
            delete_hardlinks_to_node(node.id)
          end

          # Nullify any foreign key references from torrents to this directory
          # This allows the directory deletion to proceed without constraint violations
          nullify_torrent_node_references(node.id)

          Repo.delete!(node)
        end

      # Handle regular file
      true ->
        # If cascade_hardlinks is true, delete all hard links pointing to this file
        if cascade_hardlinks do
          delete_hardlinks_to_node(node.id)
        end

        Repo.delete!(node)
    end
  end

  # Helper to delete all hard links pointing to a target node
  defp delete_hardlinks_to_node(target_node_id) do
    hardlinks = find_all_hardlinks_to_target(target_node_id)
    Enum.each(hardlinks, fn link -> Repo.delete!(link) end)
  end

  # Helper to nullify foreign key references from torrents to a node
  # This prevents constraint violations when deleting a node that torrents reference
  defp nullify_torrent_node_references(node_id) do
    from(t in "torrents", where: t.node_id == ^node_id)
    |> Repo.update_all(set: [node_id: nil])
  end

  @doc """
  Counts the number of hard links pointing to a specific target node.
  Returns 0 if no hard links exist.
  """
  def count_hardlinks_to_target(target_node_id) do
    Repo.one(
      from(n in Node,
        where: n.is_hardlink == true and n.hardlink_target_node_id == ^target_node_id,
        select: count(n.id)
      )
    ) || 0
  end

  @doc """
  Finds all hard link nodes pointing to a specific target node.
  Returns a list of nodes (may be empty).
  """
  def find_all_hardlinks_to_target(target_node_id) do
    Repo.all(
      from(node in Node,
        where: node.is_hardlink == true and node.hardlink_target_node_id == ^target_node_id,
        order_by: node.name
      )
    )
  end

  @doc """
   Updates the data and size of a node.
  """
  def write_data(node_id, data, offset \\ 0) do
    node = Repo.get!(Node, node_id)

    new_data =
      case offset do
        0 ->
          data

        _ ->
          existing = node.data || <<>>
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

    node
    |> Node.changeset(%{
      data: new_data,
      size: byte_size(new_data)
    })
    |> Repo.update()
  end

  @doc """
  Reads data from a node with optional offset and size.
  """
  def read_data(node_id, offset \\ 0, size \\ nil) do
    case get_node(node_id) do
      {:ok, node} ->
        data = node.data || <<>>

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
  Updates node attributes.
  """
  def update_node(node_id, attrs) do
    node = Repo.get!(Node, node_id)

    node
    |> Node.changeset(attrs)
    |> Repo.update()
  end

  @doc """
   Creates a hardlink to a virtual inode (torrent file).

   Virtual inodes are backed by torrent_files records instead of regular VFS nodes.
   The hardlink stores the torrent_file_id in hardlink_target_torrent_file_id field.

  ## Parameters
    - `parent_id`: Parent directory node ID
    - `name`: Name of the hardlink
    - `virtual_inode_id`: ID of the torrent_file (virtual inode)
    - `opts`: Options including :size for file size

  ## Returns
    - `{:ok, node}` on success
    - `{:error, reason}` on failure
  """
  def create_hardlink_to_virtual_inode(parent_id, name, virtual_inode_id, opts \\ []) do
    size = Keyword.get(opts, :size, 0)
    inode_ref = "vi:#{virtual_inode_id}"

    %Node{}
    |> Node.changeset(%{
      parent_id: parent_id,
      name: name,
      mode: FileMode.file_mode(),
      data: inode_ref,
      size: size,
      is_hardlink: true,
      hardlink_target_torrent_file_id: virtual_inode_id
    })
    |> Repo.insert()
  end

  @doc """
  Counts hardlinks pointing to a virtual inode.

  Returns the number of nodes marked as hardlinks pointing to the given virtual inode.
  """
  def count_hardlinks_to_virtual_inode(virtual_inode_id) do
    Repo.one(
      from(n in Node,
        where: n.is_hardlink == true and n.hardlink_target_torrent_file_id == ^virtual_inode_id,
        select: count(n.id)
      )
    ) || 0
  end

  @doc """
  Finds all hardlinks pointing to a virtual inode.

  Returns a list of nodes that reference the given virtual inode.
  """
  def find_all_hardlinks_to_virtual_inode(virtual_inode_id) do
    Repo.all(
      from(node in Node,
        where:
          node.is_hardlink == true and node.hardlink_target_torrent_file_id == ^virtual_inode_id,
        order_by: node.name
      )
    )
  end

  @doc """
  Checks if a node is a hardlink.

  A node is a hardlink if its is_hardlink flag is explicitly set to true.
  Handles both boolean true and integer 1 (from legacy database).
  This is POSIX-idiomatic and efficiently checks the explicit flag rather than parsing data.

  Returns true if it's a hardlink, false otherwise.
  """
  def is_hardlink?(node) do
    node.is_hardlink == true or node.is_hardlink == 1
  end

  @doc """
  Extracts the virtual inode ID from a hardlink.

  Returns:
  - `{:ok, virtual_inode_id}` if it's a virtual inode hardlink
  - `{:error, :not_virtual_inode}` if it's a regular POSIX hardlink
  - `{:error, :not_a_hardlink}` if not a hardlink
  """
  def extract_virtual_inode_id(node) when is_map(node) do
    # Note: is_hardlink can be 0/1 (from old DB as integer) or false/true (boolean)
    is_hardlink_value = node.is_hardlink == true or node.is_hardlink == 1

    cond do
      # Not a hardlink at all
      !is_hardlink_value ->
        {:error, :not_a_hardlink}

      # Virtual inode hardlink
      node.hardlink_target_torrent_file_id ->
        {:ok, node.hardlink_target_torrent_file_id}

      # Regular POSIX hardlink
      true ->
        {:error, :not_virtual_inode}
    end
  end

  def extract_virtual_inode_id(_), do: {:error, :not_a_hardlink}
end
