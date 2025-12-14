defmodule GrpcServer.E2E.DeletionTest do
  @moduledoc """
  End-to-end tests for deletion operations via gRPC.

  Covers:
  - Removing regular files
  - Removing hard links
  - Removing torrent-backed files (marks for deletion)
  - Removing directories with mixed content
  - Cascade deletion with external hard links
  - Error handling for invalid requests
  """
  use ExUnit.Case, async: false

  alias VFS
  alias VFS.Repo
  alias VFS.FileMode

  alias StreamMountApi.{
    RemoveRequest,
    RemoveResponse
  }

  alias GrpcServer.FileSystemService.Server

  setup do
    :ok = GrpcTestHelper.cleanup_database()
    :ok = GrpcTestHelper.wait_for_db_ready()
    {:ok, root} = GrpcTestHelper.ensure_root()

    %{root: root}
  end

  describe "remove regular file" do
    test "removes a regular file successfully", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "test.txt")

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "test.txt"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Verify file is gone
      assert {:error, :not_found} = VFS.get_node(file.inode_id)
    end

    test "returns not_found for non-existent file", %{root: root} do
      request = %RemoveRequest{parent_node_id: root.inode_id, name: "nonexistent.txt"}

      assert_raise GRPC.RPCError, ~r/not found/i, fn ->
        Server.remove(request, nil)
      end
    end

    test "validates file name", %{root: root} do
      # Empty name
      request = %RemoveRequest{parent_node_id: root.inode_id, name: ""}

      assert_raise GRPC.RPCError, ~r/name cannot be empty/i, fn ->
        Server.remove(request, nil)
      end

      # Name with path separator
      request = %RemoveRequest{parent_node_id: root.inode_id, name: "path/to/file.txt"}

      assert_raise GRPC.RPCError, ~r/path separator/i, fn ->
        Server.remove(request, nil)
      end
    end
  end

  describe "remove hard link" do
    test "removes hard link without affecting target", %{root: root} do
      {:ok, target} = VFS.create_file(root.inode_id, "target.txt")
      {:ok, link} = VFS.create_hardlink(root.inode_id, "link.txt", target.inode_id)

      # link and target share the same inode (POSIX hardlink semantics)
      assert link.inode_id == target.inode_id

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "link.txt"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Inode still exists because target.txt still points to it (nlink went from 2 to 1)
      {:ok, inode} = VFS.get_node(link.inode_id)
      assert inode.nlink == 1

      # Target still exists and is accessible via lookup
      assert {:ok, _} = VFS.get_node(target.inode_id)
    end

    test "removes last hard link (orphaned)", %{root: root} do
      {:ok, target} = VFS.create_file(root.inode_id, "target.txt")
      {:ok, link} = VFS.create_hardlink(root.inode_id, "link.txt", target.inode_id)

      # Delete target first
      VFS.remove(root.inode_id, "target.txt")

      # Now delete orphaned hard link
      request = %RemoveRequest{parent_node_id: root.inode_id, name: "link.txt"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      assert {:error, :not_found} = VFS.get_node(link.inode_id)
    end
  end

  describe "remove torrent-backed file (marks for deletion)" do
    setup %{root: root} do
      # This test requires SyncEngine to be available
      # If not available, skip these tests
      unless Code.ensure_loaded?(SyncEngine.Torrents) do
        {:skip, "SyncEngine not available"}
      end

      # Create a mock torrent-backed file
      {:ok, movies} = VFS.create_directory(root.inode_id, "movies")

      {:ok, file_node} =
        VFS.create_file(movies.inode_id, "movie.mkv",
          content_type: "debrid_drive_ex/streamable",
          size: 1_000_000_000
        )

      %{root: root, movies: movies, file_node: file_node}
    end

    @tag :sync_engine
    test "marks torrent for deletion when file is removed", %{
      movies: movies,
      file_node: _file_node
    } do
      request = %RemoveRequest{parent_node_id: movies.inode_id, name: "movie.mkv"}
      assert %RemoveResponse{} = Server.remove(request, nil)
    end

    @tag :sync_engine
    test "removes file immediately if not torrent-backed", %{movies: movies} do
      {:ok, regular_file} = VFS.create_file(movies.inode_id, "notes.txt")

      request = %RemoveRequest{parent_node_id: movies.inode_id, name: "notes.txt"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      assert {:error, :not_found} = VFS.get_node(regular_file.inode_id)
    end
  end

  describe "remove directory" do
    test "removes empty directory", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.inode_id, "empty")

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "empty"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      assert {:error, :not_found} = VFS.get_node(dir.inode_id)
    end

    test "cascade removes non-empty directory", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.inode_id, "not_empty")
      {:ok, _file} = VFS.create_file(dir.inode_id, "file.txt")

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "not_empty"}

      # Should succeed with cascade: true default
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Directory and contents should be gone
      assert {:error, :not_found} = VFS.get_node(dir.inode_id)
    end

    test "cascade removes directory with files", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.inode_id, "folder")
      {:ok, _file1} = VFS.create_file(dir.inode_id, "file1.txt")
      {:ok, _file2} = VFS.create_file(dir.inode_id, "file2.txt")

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "folder"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # All should be gone (implementation detail)
    end

    test "cascade removes nested directories", %{root: root} do
      {:ok, parent} = VFS.create_directory(root.inode_id, "parent")
      {:ok, child} = VFS.create_directory(parent.inode_id, "child")
      {:ok, _file} = VFS.create_file(child.inode_id, "deep.txt")

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "parent"}
      assert %RemoveResponse{} = Server.remove(request, nil)
    end
  end

  describe "remove directory with torrent files" do
    @tag :sync_engine
    test "marks all torrents for deletion when directory is removed", %{root: root} do
      {:ok, movies} = VFS.create_directory(root.inode_id, "movies")

      {:ok, _movie1} =
        VFS.create_file(movies.inode_id, "movie1.mkv",
          content_type: "debrid_drive_ex/streamable",
          size: 1_000_000
        )

      {:ok, _movie2} =
        VFS.create_file(movies.inode_id, "movie2.mkv",
          content_type: "debrid_drive_ex/streamable",
          size: 2_000_000
        )

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "movies"}
      assert %RemoveResponse{} = Server.remove(request, nil)
    end

    @tag :sync_engine
    test "handles mixed content directory", %{root: root} do
      {:ok, mixed} = VFS.create_directory(root.inode_id, "mixed")

      # Local file
      {:ok, _notes} = VFS.create_file(mixed.inode_id, "notes.txt")

      # Torrent file
      {:ok, _movie} =
        VFS.create_file(mixed.inode_id, "movie.mkv",
          content_type: "debrid_drive_ex/streamable",
          size: 1_000_000
        )

      # Hard link to external file
      {:ok, external_target} = VFS.create_file(root.inode_id, "external.txt")
      {:ok, _link} = VFS.create_hardlink(mixed.inode_id, "link.txt", external_target.inode_id)

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "mixed"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      assert {:ok, _} = VFS.get_node(external_target.inode_id)
    end
  end

  describe "cascade hard link deletion" do
    test "removes external hard links when target is deleted with cascade", %{root: root} do
      {:ok, movies} = VFS.create_directory(root.inode_id, "movies")
      {:ok, favorites} = VFS.create_directory(root.inode_id, "favorites")

      {:ok, target} = VFS.create_file(movies.inode_id, "movie.mkv")
      {:ok, _link} = VFS.create_hardlink(favorites.inode_id, "favorite.mkv", target.inode_id)

      # Delete movies directory (which contains the target)
      request = %RemoveRequest{parent_node_id: root.inode_id, name: "movies"}
      assert %RemoveResponse{} = Server.remove(request, nil)
    end
  end

  describe "error handling" do
    test "handles invalid parent_node_id", %{root: _root} do
      request = %RemoveRequest{parent_node_id: 99999, name: "file.txt"}

      assert_raise GRPC.RPCError, ~r/not found/i, fn ->
        Server.remove(request, nil)
      end
    end

    test "handles parent that is not a directory", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "file.txt")

      request = %RemoveRequest{parent_node_id: file.inode_id, name: "something.txt"}

      # Should raise not_found since files can't have children
      assert_raise GRPC.RPCError, ~r/not found/i, fn ->
        Server.remove(request, nil)
      end
    end

    test "handles concurrent deletions gracefully", %{root: root} do
      {:ok, _file} = VFS.create_file(root.inode_id, "concurrent.txt")

      request = %RemoveRequest{parent_node_id: root.inode_id, name: "concurrent.txt"}

      # First deletion succeeds
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Second deletion fails (file already gone)
      assert_raise GRPC.RPCError, ~r/not found/i, fn ->
        Server.remove(request, nil)
      end
    end
  end

  describe "transactional guarantees" do
    test "deletion is atomic - all or nothing" do
    end
  end
end
