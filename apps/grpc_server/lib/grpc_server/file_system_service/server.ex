defmodule GrpcServer.FileSystemService.Server do
  @moduledoc """
  gRPC server implementation for FileSystemService.
  Maps RPC calls to VFS operations.
  """

  use GRPC.Server, service: StreamMountApi.FileSystemService.Service

  require Logger
  import Bitwise

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
        %RootResponse{root: node_to_proto(root)}

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
      nodes = Enum.map(children, &node_to_proto/1)

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
      {:ok, node} ->
        %LookupResponse{node: node_to_proto(node)}

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
      {:ok, node} ->
        %CreateResponse{node: node_to_proto(node)}

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
      {:ok, node} ->
        %MkdirResponse{node: node_to_proto(node)}

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

  # Handle remove with special logic for hardlinks
  # If it's a hardlink, decrement reference count. Otherwise, cascade delete.
  defp handle_remove(parent_id, name) do
    with {:ok, node} <- VFS.lookup(parent_id, name) do
      if VFS.is_hardlink?(node) do
        # Hardlink: handle reference counting
        handle_hardlink_remove(node)
      else
        # Regular node: cascade delete
        VFS.remove(parent_id, name, cascade: true)
      end
    end
  end

  # Handle hardlink removal with virtual inode reference counting
  defp handle_hardlink_remove(hardlink_node) do
    case VFS.extract_virtual_inode_id(hardlink_node) do
      {:ok, inode_id} ->
        handle_virtual_inode_remove(hardlink_node, inode_id)

      {:error, _} ->
        # Not a valid hardlink, just remove it
        VFS.remove_by_id(hardlink_node.id, cascade: false)
    end
  end

  # Handle virtual inode hardlink removal with reference counting
  defp handle_virtual_inode_remove(hardlink_node, virtual_inode_id) do
    case SyncEngine.Torrents.get_torrent_file_by_id(virtual_inode_id) do
      {:ok, virtual_inode} ->
        # Decrement hardlink count
        case SyncEngine.Torrents.decrement_hardlink_count(virtual_inode) do
          {:ok, {_new_count, should_delete_torrent}} ->
            # Remove the hardlink node
            case VFS.remove_by_id(hardlink_node.id, cascade: false) do
              :ok ->
                # If all hardlinks removed, enqueue torrent deletion
                if should_delete_torrent do
                  enqueue_torrent_deletion_on_remove(virtual_inode)
                end

                :ok

              error ->
                error
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        # Virtual inode already deleted, just remove the orphaned link
        VFS.remove_by_id(hardlink_node.id, cascade: false)
    end
  end

  # Enqueue torrent deletion when last hardlink is removed
  defp enqueue_torrent_deletion_on_remove(virtual_inode) do
    case SyncEngine.Torrents.get_torrent(virtual_inode.torrent_id) do
      {:ok, torrent} ->
        Logger.info(
          "All hardlinks removed for torrent #{torrent.rd_id}, " <>
            "enqueueing deletion from RealDebrid"
        )

        # Queue deletion job
        SyncEngine.Workers.DeletionWorker.enqueue(torrent.id)
        :ok

      {:error, :not_found} ->
        # Torrent already deleted
        :ok
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

    with {:ok, node} <- VFS.lookup(old_parent_id, old_name),
         {:ok, updated_node} <- VFS.move(node.id, new_parent_id, new_name) do
      %RenameResponse{node: node_to_proto(updated_node)}
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

    # Create hard link to target node
    case VFS.create_hardlink(parent_id, name, target_node_id) do
      {:ok, link_node} ->
        %LinkResponse{node: node_to_proto(link_node)}

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
  end

  @doc """
  Sets file attributes (mode, size, timestamps, ownership).

  This is primarily used by FUSE for operations like chmod, truncate, touch, and chown.
  Only provided fields are updated; nil fields are ignored.
  """
  @spec setattr(SetattrRequest.t(), GRPC.Server.Stream.t()) :: SetattrResponse.t()
  def setattr(%SetattrRequest{node_id: node_id} = request, _stream) do
    with {:ok, node} <- VFS.get_node(node_id),
         {:ok, updated_node} <- apply_setattr(node, request) do
      %SetattrResponse{node: node_to_proto(updated_node)}
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

  @doc """
  Reads file data.
  """
  @spec read_file(ReadFileRequest.t(), GRPC.Server.Stream.t()) :: ReadFileResponse.t()
  def read_file(%ReadFileRequest{node_id: node_id, offset: offset, size: size}, _stream) do
    # Convert 0 size to nil (read all)
    read_size = if size == 0, do: nil, else: size

    # Resolve hard links to their target
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

      {:error, _reason} ->
        raise GRPC.RPCError, status: :internal, message: "Read operation failed"
    end
  end

  @doc """
  Writes file data.
  """
  @spec write_file(WriteFileRequest.t(), GRPC.Server.Stream.t()) :: WriteFileResponse.t()
  def write_file(%WriteFileRequest{node_id: node_id, offset: offset, data: data}, _stream) do
    # Resolve hard links to their target
    with {:ok, target_id} <- resolve_for_file_ops(node_id),
         {:ok, _node} <- VFS.write_data(target_id, data, offset) do
      %WriteFileResponse{bytes_written: byte_size(data)}
    else
      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Node not found"

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
      {:ok, node} ->
        # Convert Elixir NaiveDateTime to Unix timestamp
        {atime, atime_nsec} = datetime_to_unix(node.updated_at)
        {mtime, mtime_nsec} = datetime_to_unix(node.updated_at)
        {ctime, ctime_nsec} = datetime_to_unix(node.inserted_at)

        %GetFileInfoResponse{
          size: node.size || 0,
          mode: node.mode,
          atime: atime,
          atime_nsec: atime_nsec,
          mtime: mtime,
          mtime_nsec: mtime_nsec,
          ctime: ctime,
          ctime_nsec: ctime_nsec,
          uid: 0,
          gid: 0,
          nlink: 1
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
    with {:ok, node} <- VFS.get_node(node_id),
         {:ok, torrent_file} <- resolve_to_torrent_file(node),
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

  defp node_to_proto(node) do
    # Convert Elixir NaiveDateTime to Unix timestamp
    {atime, atime_nsec} = datetime_to_unix(node.updated_at)
    {mtime, mtime_nsec} = datetime_to_unix(node.updated_at)
    {ctime, ctime_nsec} = datetime_to_unix(node.inserted_at)

    %Node{
      id: node.id,
      name: node.name,
      mode: node.mode,
      streamable: is_streamable?(node),
      size: node.size || 0,
      atime: atime,
      atime_nsec: atime_nsec,
      mtime: mtime,
      mtime_nsec: mtime_nsec,
      ctime: ctime,
      ctime_nsec: ctime_nsec,
      uid: 0,
      gid: 0,
      nlink: 1
    }
  end

  defp is_streamable?(node) do
    VFS.Streamability.streamable?(node)
  end

  # Helper to resolve a hard link to its target node
  # Virtual inode hardlinks point to streamable torrent files and can be used for streaming.
  defp resolve_link_target(node) do
    case VFS.extract_virtual_inode_id(node) do
      {:ok, inode_id} ->
        # Virtual inode - get the torrent file
        case SyncEngine.Torrents.get_torrent_file_by_id(inode_id) do
          {:ok, torrent_file} ->
            {:ok, torrent_file}

          error ->
            error
        end

      {:error, _} ->
        # Regular POSIX hardlink - get the target VFS node
        target_node_id = node.hardlink_target_node_id
        VFS.get_node(target_node_id)
    end
  end

  # Resolves a node ID for file operations (read, write, etc.)
  # If the node is a hard link, returns the target node ID
  # Otherwise returns the original node ID
  defp resolve_for_file_ops(node_id) do
    with {:ok, node} <- VFS.get_node(node_id) do
      if VFS.is_hardlink?(node) do
        # Hard link - resolve to target
        case resolve_link_target(node) do
          {:ok, target_node} ->
            # Hard links cannot chain to other hard links, so target_node is always a regular file
            {:ok, target_node.id}

          error ->
            error
        end
      else
        # Regular file or directory - return as-is
        {:ok, node_id}
      end
    end
  end

  # Resolves a hardlink or virtual inode to its torrent file for streaming
  # Only hardlinks (pointing to virtual inodes) can be streamed, never regular files.
  # Regular files are read/write from disk and don't support streaming.
  defp resolve_to_torrent_file(node) do
    cond do
      # Only hardlinks pointing to virtual inodes can be streamable
      VFS.is_hardlink?(node) ->
        Logger.info(
          "resolve_to_torrent_file: resolving hardlink node_id=#{node.id}, node_target=#{node.hardlink_target_node_id}, inode_target=#{node.hardlink_target_torrent_file_id}"
        )

        case VFS.extract_virtual_inode_id(node) do
          {:ok, inode_id} ->
            # Virtual inode hardlink - get torrent_file directly by ID
            Logger.info("resolve_to_torrent_file: hardlink points to virtual inode #{inode_id}")

            case SyncEngine.Torrents.get_torrent_file_by_id(inode_id) do
              {:ok, torrent_file} ->
                Logger.info("resolve_to_torrent_file: got virtual inode torrent_file")
                {:ok, torrent_file}

              error ->
                error
            end

          {:error, _} ->
            # Regular POSIX hardlink - not streamable
            Logger.info("resolve_to_torrent_file: regular hardlink is not streamable")
            {:error, :not_streamable}
        end

      true ->
        # Regular files are not streamable (they're read/write from disk)
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
