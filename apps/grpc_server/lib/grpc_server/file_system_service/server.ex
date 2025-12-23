defmodule GrpcServer.FileSystemService.Server do
  @moduledoc """
  gRPC server implementation for FileSystemService.
  Maps RPC calls to VFS operations.
  """

  use GRPC.Server, service: StreamMountApi.FileSystemService.Service

  require Logger
  import Bitwise
  import Ecto.Query

  alias VFS
  alias VFS.FileMode
  alias SyncEngine.Schemas.TorrentFile

  alias StreamMountApi.{
    RootRequest,
    RootResponse,
    ReadDirAllRequest,
    ReadDirAllResponse,
    LookupRequest,
    LookupResponse,
    CreateRequest,
    CreateResponse,
    MkdirRequest,
    MkdirResponse,
    RemoveRequest,
    RemoveResponse,
    RenameRequest,
    RenameResponse,
    LinkRequest,
    LinkResponse,
    SetattrRequest,
    SetattrResponse,
    ReadFileRequest,
    ReadFileResponse,
    WriteFileRequest,
    WriteFileResponse,
    GetFileInfoRequest,
    GetFileInfoResponse,
    GetStreamUrlRequest,
    GetStreamUrlResponse,
    Node
  }

  @doc """
  Returns the root node of the filesystem.
  """
  @spec root(RootRequest.t(), GRPC.Server.Stream.t()) :: RootResponse.t()
  def root(_request, _stream) do
    case VFS.get_root() do
      {:ok, root} ->
        %RootResponse{root: inode_to_proto(root, "/")}

      {:error, _reason} ->
        raise GRPC.RPCError, status: :internal, message: "Failed to retrieve root node"
    end
  end

  @doc """
  Lists all children of a directory.
  """
  @spec read_dir_all(ReadDirAllRequest.t(), GRPC.Server.Stream.t()) :: ReadDirAllResponse.t()
  def read_dir_all(%ReadDirAllRequest{node_id: node_id}, _stream) do
    with {:ok, node} <- VFS.get_node(node_id),
         true <- FileMode.dir?(node.mode) do
      children = VFS.list_children(node_id)
      # list_children returns {directory_entry, inode} tuples
      nodes = Enum.map(children, fn {entry, inode} -> inode_to_proto(inode, entry.name) end)

      %ReadDirAllResponse{nodes: nodes}
    else
      {:error, :not_found} ->
        # Return empty list for FUSE ENOENT
        %ReadDirAllResponse{nodes: []}

      false ->
        raise GRPC.RPCError, status: :invalid_argument, message: "Not a directory"
    end
  end

  @doc """
  Looks up a child node by name.
  """
  @spec lookup(LookupRequest.t(), GRPC.Server.Stream.t()) :: LookupResponse.t()
  def lookup(%LookupRequest{node_id: node_id, name: name}, _stream) do
    validate_name!(name)

    case VFS.lookup(node_id, name) do
      {:ok, inode} ->
        %LookupResponse{node: inode_to_proto(inode, name)}

      {:error, :not_found} ->
        # Return empty response for FUSE ENOENT
        %LookupResponse{}
    end
  end

  @doc """
  Creates a new file.
  """
  @spec create(CreateRequest.t(), GRPC.Server.Stream.t()) :: CreateResponse.t()
  def create(%CreateRequest{parent_node_id: parent_id, name: name, mode: mode}, _stream) do
    validate_name!(name)

    # Extract permissions from mode (lower 9 bits)
    permissions = mode &&& 0o777

    case VFS.create_file(parent_id, name, mode: permissions) do
      {:ok, inode} ->
        %CreateResponse{node: inode_to_proto(inode, name)}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        raise GRPC.RPCError, status: :internal, message: "Create failed: #{inspect(errors)}"

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: "Create failed: #{inspect(reason)}"
    end
  end

  @doc """
  Creates a new directory.
  """
  @spec mkdir(MkdirRequest.t(), GRPC.Server.Stream.t()) :: MkdirResponse.t()
  def mkdir(%MkdirRequest{parent_node_id: parent_id, name: name}, _stream) do
    validate_name!(name)

    case VFS.create_directory(parent_id, name) do
      {:ok, inode} ->
        %MkdirResponse{node: inode_to_proto(inode, name)}

      {:error, _reason} ->
        raise GRPC.RPCError, status: :internal, message: "Mkdir operation failed"
    end
  end

  @doc """
  Removes a node.

  For regular files/directories: removes recursively (cascade: true).
  For hardlinks: decrements hardlink_count and enqueues torrent deletion if needed.
  Torrent-backed files are marked for deletion and cleaned up by SyncEngine.
  """
  @spec remove(RemoveRequest.t(), GRPC.Server.Stream.t()) :: RemoveResponse.t()
  def remove(%RemoveRequest{parent_node_id: parent_id, name: name}, _stream) do
    validate_name!(name)

    case handle_remove(parent_id, name) do
      :ok ->
        %RemoveResponse{}

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Node not found"

      {:error, :directory_not_empty} ->
        raise GRPC.RPCError, status: :failed_precondition, message: "Directory not empty"

      {:error, :cannot_delete_root} ->
        raise GRPC.RPCError, status: :permission_denied, message: "Cannot delete root node"

      {:error, reason} ->
        Logger.error("Remove operation failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: "Remove operation failed"
    end
  end

  # Handle remove with special logic for virtual inodes
  # If it's a virtual inode, decrement reference count. Otherwise, cascade delete.
  defp handle_remove(parent_id, name) do
    with {:ok, inode} <- VFS.lookup(parent_id, name) do
      if VFS.is_hardlink?(inode) do
        # Virtual inode: handle reference counting
        handle_hardlink_remove(inode, parent_id, name)
      else
        # Regular inode: cascade delete
        VFS.remove(parent_id, name, cascade: true)
      end
    end
  end

  # Handle virtual inode removal with reference counting
  defp handle_hardlink_remove(inode, parent_id, name) do
    case VFS.extract_virtual_inode_id(inode) do
      {:ok, virtual_inode_id} ->
        handle_virtual_inode_remove(inode, virtual_inode_id, parent_id, name)

      {:error, _} ->
        # Regular inode, just remove it
        VFS.remove(parent_id, name, cascade: false)
    end
  end

  # Handle virtual inode removal with reference counting
  # The VFS.remove function now handles nlink decrement automatically
  defp handle_virtual_inode_remove(inode, virtual_inode_id, parent_id, name) do
    VFS.Repo.transact(fn ->
      case SyncEngine.Torrents.get_torrent_file_by_id(virtual_inode_id) do
        {:ok, torrent_file} ->
          # Store torrent_rd_id before removal for potential deletion
          torrent_rd_id = torrent_file.torrent_rd_id

          # Remove the directory entry (VFS handles nlink decrement and calls decrement_hardlink_count)
          case VFS.remove(parent_id, name, cascade: false) do
            :ok ->
              # Check if all files in this torrent instance have zero hardlinks
              SyncEngine.Services.DeletionPolicy.maybe_enqueue_deletion(
                torrent_file.torrent_hash,
                torrent_rd_id
              )

              {:ok, :ok}

            error ->
              VFS.Repo.rollback(error)
          end

        {:error, :not_found} ->
          # Virtual inode already deleted, just remove the orphaned link
          case VFS.remove(parent_id, name, cascade: false) do
            :ok -> {:ok, :ok}
            error -> VFS.Repo.rollback(error)
          end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, other} -> other
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Renames/moves a node.
  """
  @spec rename(RenameRequest.t(), GRPC.Server.Stream.t()) :: RenameResponse.t()
  def rename(
        %RenameRequest{
          old_parent_node_id: old_parent_id,
          old_name: old_name,
          new_parent_node_id: new_parent_id,
          new_name: new_name
        },
        _stream
      ) do
    validate_name!(old_name)
    validate_name!(new_name)

    with {:ok, _result} <- VFS.move(old_parent_id, old_name, new_parent_id, new_name),
         {:ok, updated_inode} <- VFS.lookup(new_parent_id, new_name) do
      %RenameResponse{node: inode_to_proto(updated_inode, new_name)}
    else
      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Node not found"

      {:error, _reason} ->
        raise GRPC.RPCError, status: :internal, message: "Rename operation failed"
    end
  end

  @doc """
  Creates a hard link to an existing node.

  The link appears as a regular file with the same mode and metadata as the target.
  File operations on the link transparently resolve to the target node.

  The link is created at parent_node_id/name and points to node_id.
  The target node_id is stored as a string in the link's data field.
  """
  @spec link(LinkRequest.t(), GRPC.Server.Stream.t()) :: LinkResponse.t()
  def link(%LinkRequest{node_id: target_node_id, parent_node_id: parent_id, name: name}, _stream) do
    validate_name!(name)

    # Create hard link to target inode
    try do
      case VFS.create_hardlink(parent_id, name, target_node_id) do
        {:ok, inode} ->
          %LinkResponse{node: inode_to_proto(inode, name)}

        {:error, :not_found} ->
          raise GRPC.RPCError, status: :not_found, message: "Target node not found"

        {:error, :cannot_link_to_hardlink} ->
          raise GRPC.RPCError,
            status: :invalid_argument,
            message: "Cannot create a hard link to another hard link"

        {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
          # Handle validation errors
          errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

          raise GRPC.RPCError,
            status: :invalid_argument,
            message: "Invalid link: #{inspect(errors)}"

        {:error, _reason} ->
          raise GRPC.RPCError, status: :internal, message: "Link operation failed"
      end
    rescue
      Ecto.NoResultsError ->
        raise GRPC.RPCError, status: :not_found, message: "Target node not found"
    end
  end

  @doc """
  Sets file attributes (mode, size, timestamps, ownership).

  This is primarily used by FUSE for operations like chmod, truncate, touch, and chown.
  Only provided fields are updated; nil fields are ignored.
  """
  @spec setattr(SetattrRequest.t(), GRPC.Server.Stream.t()) :: SetattrResponse.t()
  def setattr(%SetattrRequest{node_id: node_id} = request, _stream) do
    # For setattr, we need to get the name from a directory entry
    # Since an inode can have multiple names (hardlinks), we'll just use the first one we find
    with {:ok, inode} <- VFS.get_node(node_id),
         {:ok, updated_inode} <- apply_setattr(inode, request) do
      # Get any name for this inode for the response
      name = get_any_name_for_inode(inode.inode_id)
      %SetattrResponse{node: inode_to_proto(updated_inode, name)}
    else
      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Node not found"

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "Invalid attributes: #{inspect(errors)}"

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :internal,
          message: "Setattr operation failed: #{inspect(reason)}"
    end
  end

  # Helper to get any name for an inode (for cases where we don't have the directory entry context)
  # Returns a name if found, or "(deleted)" if the inode has no directory entries
  defp get_any_name_for_inode(inode_id) do
    case VFS.DirectoryEntry
         |> where([directory_entry], directory_entry.inode_id == ^inode_id)
         |> limit(1)
         |> select([directory_entry], directory_entry.name)
         |> VFS.Repo.one() do
      nil -> "(deleted)"
      name -> name
    end
  end

  @doc """
  Reads file data.
  """
  @spec read_file(ReadFileRequest.t(), GRPC.Server.Stream.t()) :: ReadFileResponse.t()
  def read_file(%ReadFileRequest{node_id: node_id, offset: offset, size: size}, _stream) do
    # Convert 0 size to nil (read all)
    read_size = if size == 0, do: nil, else: size

    # Validate the inode is suitable for read operations (not a virtual inode)
    case resolve_for_file_ops(node_id) do
      {:ok, target_id} ->
        # Regular file: read from database
        case VFS.read_data(target_id, offset, read_size) do
          {:ok, data} ->
            %ReadFileResponse{data: data}

          {:error, :not_found} ->
            raise GRPC.RPCError, status: :not_found, message: "Node not found"

          {:error, _reason} ->
            raise GRPC.RPCError, status: :internal, message: "Read operation failed"
        end

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Node not found"

      {:error, :virtual_inode_not_writable} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "Cannot read virtual inode data directly (use get_stream_url for streaming)"

      {:error, _reason} ->
        raise GRPC.RPCError, status: :internal, message: "Read operation failed"
    end
  end

  @doc """
  Writes file data.
  """
  @spec write_file(WriteFileRequest.t(), GRPC.Server.Stream.t()) :: WriteFileResponse.t()
  def write_file(%WriteFileRequest{node_id: node_id, offset: offset, data: data}, _stream) do
    # Validate the inode is suitable for write operations (not a virtual inode)
    with {:ok, target_id} <- resolve_for_file_ops(node_id),
         {:ok, _node} <- VFS.write_data(target_id, data, offset) do
      %WriteFileResponse{bytes_written: byte_size(data)}
    else
      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Node not found"

      {:error, :virtual_inode_not_writable} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "Cannot write to virtual inode (streamable file)"

      {:error, _reason} ->
        raise GRPC.RPCError, status: :internal, message: "Write operation failed"
    end
  end

  @doc """
  Gets file information (size and mode).
  """
  @spec get_file_info(GetFileInfoRequest.t(), GRPC.Server.Stream.t()) :: GetFileInfoResponse.t()
  def get_file_info(%GetFileInfoRequest{node_id: node_id}, _stream) do
    case VFS.get_node(node_id) do
      {:ok, inode} ->
        # Convert Elixir NaiveDateTime to Unix timestamp
        {atime, atime_nsec} = datetime_to_unix(inode.updated_at)
        {mtime, mtime_nsec} = datetime_to_unix(inode.updated_at)
        {ctime, ctime_nsec} = datetime_to_unix(inode.inserted_at)

        %GetFileInfoResponse{
          size: inode.size || 0,
          mode: inode.mode,
          atime: atime,
          atime_nsec: atime_nsec,
          mtime: mtime,
          mtime_nsec: mtime_nsec,
          ctime: ctime,
          ctime_nsec: ctime_nsec,
          uid: 0,
          gid: 0,
          nlink: inode.nlink
        }

      {:error, :not_found} ->
        # Return empty response for FUSE ENOENT
        %GetFileInfoResponse{}
    end
  end

  @doc """
  Gets a streaming URL for a file by fetching the unrestricted download link from Real Debrid.
  Supports both regular files and hard links (follows hard links to get the target's stream URL).
  Uses cached links when available and valid.
  """
  @spec get_stream_url(GetStreamUrlRequest.t(), GRPC.Server.Stream.t()) ::
          GetStreamUrlResponse.t()
  def get_stream_url(%GetStreamUrlRequest{node_id: node_id}, _stream) do
    with {:ok, inode} <- VFS.get_node(node_id),
         {:ok, torrent_file} <- resolve_to_torrent_file(inode),
         {:ok, download_url} <- get_or_fetch_download_url(torrent_file) do
      %GetStreamUrlResponse{url: download_url}
    else
      {:error, :not_found} ->
        # Return empty response for FUSE ENOENT
        %GetStreamUrlResponse{}

      {:error, :not_streamable} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "Node is not a streamable file"

      {:error, :no_link} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "File has no link for unrestricting"

      {:error, _reason} ->
        raise GRPC.RPCError, status: :internal, message: "Get stream URL operation failed"
    end
  end

  # Private helper functions

  # Validates a filename, raising appropriate gRPC errors for invalid names
  defp validate_name!(name) do
    cond do
      name == "" ->
        raise GRPC.RPCError, status: :invalid_argument, message: "Name cannot be empty"

      String.contains?(name, "/") ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "Name cannot contain path separator"

      String.contains?(name, <<0>>) ->
        raise GRPC.RPCError, status: :invalid_argument, message: "Name cannot contain null bytes"

      byte_size(name) > 255 ->
        raise GRPC.RPCError, status: :invalid_argument, message: "Name exceeds maximum length"

      true ->
        :ok
    end
  end

  # Converts an inode (with name) to the proto Node format
  defp inode_to_proto(inode, name) do
    # Convert Elixir NaiveDateTime to Unix timestamp
    {atime, atime_nsec} = datetime_to_unix(inode.updated_at)
    {mtime, mtime_nsec} = datetime_to_unix(inode.updated_at)
    {ctime, ctime_nsec} = datetime_to_unix(inode.inserted_at)

    %Node{
      id: inode.inode_id,
      name: name,
      mode: inode.mode,
      streamable: is_streamable?(inode),
      size: inode.size || 0,
      atime: atime,
      atime_nsec: atime_nsec,
      mtime: mtime,
      mtime_nsec: mtime_nsec,
      ctime: ctime,
      ctime_nsec: ctime_nsec,
      uid: 0,
      gid: 0,
      nlink: inode.nlink
    }
  end

  defp is_streamable?(inode) do
    VFS.Streamability.streamable?(inode)
  end

  # Resolves an inode for file operations (read, write, etc.)
  # Validates that an inode is suitable for file read/write operations
  # Virtual inodes (streamable files) cannot be written to, only read via streaming
  # Returns {:ok, inode_id} if suitable for file ops, or {:error, reason} if not
  defp resolve_for_file_ops(inode_id) do
    case VFS.get_node(inode_id) do
      {:ok, inode} ->
        if inode.virtual_inode_type do
          # Virtual inodes represent remote content and cannot be written to
          {:error, :virtual_inode_not_writable}
        else
          {:ok, inode_id}
        end

      error ->
        error
    end
  end

  # Resolves an inode to its torrent file for streaming
  # Only virtual inodes can be streamed
  defp resolve_to_torrent_file(inode) do
    if inode.virtual_inode_type == "torrent_file" and inode.virtual_inode_id do
      Logger.info("resolve_to_torrent_file: resolving virtual inode #{inode.inode_id} -> torrent_file #{inode.virtual_inode_id}")

      case SyncEngine.Torrents.get_torrent_file_by_id(inode.virtual_inode_id) do
        {:ok, torrent_file} ->
          Logger.info("resolve_to_torrent_file: got torrent_file")
          {:ok, torrent_file}

        error ->
          error
      end
    else
      # Regular inode - not streamable
      Logger.info("resolve_to_torrent_file: regular inode is not streamable")
      {:error, :not_streamable}
    end
  end

  # Gets the cached download URL if valid, otherwise fetches a new one from Real Debrid
  defp get_or_fetch_download_url(torrent_file) do
    if SyncEngine.Schemas.TorrentFile.link_valid?(torrent_file) do
      {:ok, torrent_file.download_link}
    else
      fetch_and_cache_download_url(torrent_file)
    end
  end

  # Fetches a new download URL from Real Debrid and caches it
  defp fetch_and_cache_download_url(%{link: nil}), do: {:error, :no_link}

  defp fetch_and_cache_download_url(torrent_file) do
    # Get shared Real-Debrid client with rate limiting
    client = SyncEngine.RealDebridClient.get_client()

    with {:ok, response} <- RealDebrid.Api.UnrestrictLink.unrestrict(client, torrent_file.link),
         changeset <-
           SyncEngine.Schemas.TorrentFile.cache_link_changeset(torrent_file, response.download),
         {:ok, updated_file} <- SyncEngine.Torrents.update_torrent_file(changeset) do
      {:ok, updated_file.download_link}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Converts NaiveDateTime to Unix timestamp (seconds since epoch) and nanoseconds
  defp datetime_to_unix(nil), do: {0, 0}

  defp datetime_to_unix(%NaiveDateTime{} = dt) do
    unix_seconds = NaiveDateTime.diff(dt, ~N[1970-01-01 00:00:00])
    # Extract microseconds and convert to nanoseconds
    nanoseconds = dt.microsecond |> elem(0) |> Kernel.*(1000)
    {unix_seconds, nanoseconds}
  end

  # Applies setattr changes to a node
  # Only updates fields that are present (not nil) in the request
  defp apply_setattr(node, request) do
    attrs = %{}

    # Handle mode change (chmod)
    attrs =
      if request.mode do
        Map.put(attrs, :mode, request.mode)
      else
        attrs
      end

    # Handle size change (truncate)
    # For now we only support truncating to 0 (clearing file)
    attrs =
      if request.size do
        cond do
          request.size == 0 ->
            Map.put(attrs, :size, 0) |> Map.put(:data, <<>>)

          request.size == node.size ->
            # No-op: size unchanged
            attrs

          true ->
            # We don't support arbitrary truncate/extend operations yet
            # This would require implementing sparse file support
            raise GRPC.RPCError,
              status: :unimplemented,
              message: "Only truncate to 0 is currently supported"
        end
      else
        attrs
      end

    # Note: We ignore atime, mtime, uid, gid for now as VFS doesn't support them yet
    # These fields are automatically managed by Ecto timestamps (inserted_at, updated_at)

    if attrs == %{} do
      # No changes requested
      {:ok, node}
    else
      # Apply changes via VFS
      VFS.Repo.update(Ecto.Changeset.change(node, attrs))
    end
  end
end
