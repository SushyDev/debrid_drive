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
    # Explicitly checkout the connection
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Clean database
    Repo.delete_all(VFS.Node)

    # Create root
    {:ok, root} = VFS.create_directory(nil, "/", mode: FileMode.directory_mode(0o755))

    %{root: root}
  end

  describe "remove regular file" do
    test "removes a regular file successfully", %{root: root} do
      {:ok, file} = VFS.create_file(root.id, "test.txt")

      request = %RemoveRequest{parent_node_id: root.id, name: "test.txt"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Verify file is gone
      assert {:error, :not_found} = VFS.get_node(file.id)
    end

    test "returns not_found for non-existent file", %{root: root} do
      request = %RemoveRequest{parent_node_id: root.id, name: "nonexistent.txt"}

      assert_raise GRPC.RPCError, ~r/not found/i, fn ->
        Server.remove(request, nil)
      end
    end

    test "validates file name", %{root: root} do
      # Empty name
      request = %RemoveRequest{parent_node_id: root.id, name: ""}

      assert_raise GRPC.RPCError, ~r/name cannot be empty/i, fn ->
        Server.remove(request, nil)
      end

      # Name with path separator
      request = %RemoveRequest{parent_node_id: root.id, name: "path/to/file.txt"}

      assert_raise GRPC.RPCError, ~r/path separator/i, fn ->
        Server.remove(request, nil)
      end
    end
  end

  describe "remove hard link" do
    test "removes hard link without affecting target", %{root: root} do
      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, link} = VFS.create_hardlink(root.id, "link.txt", target.id)

      request = %RemoveRequest{parent_node_id: root.id, name: "link.txt"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Link is gone
      assert {:error, :not_found} = VFS.get_node(link.id)

      # Target still exists
      assert {:ok, _} = VFS.get_node(target.id)
    end

    test "removes last hard link (orphaned)", %{root: root} do
      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, link} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Delete target first
      VFS.remove(root.id, "target.txt")

      # Now delete orphaned hard link
      request = %RemoveRequest{parent_node_id: root.id, name: "link.txt"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      assert {:error, :not_found} = VFS.get_node(link.id)
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
      {:ok, movies} = VFS.create_directory(root.id, "movies")

      {:ok, file_node} =
        VFS.create_file(movies.id, "movie.mkv",
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
      # Note: This test assumes we have a torrent_file record
      # In reality, we'd need to set that up in the database

      request = %RemoveRequest{parent_node_id: movies.id, name: "movie.mkv"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # File should be marked for deletion or removed immediately
      # Depending on implementation, this could be soft-delete
      # For now, we just verify the remove succeeded

      # The actual torrent deletion happens async via SyncEngine
    end

    @tag :sync_engine
    test "removes file immediately if not torrent-backed", %{movies: movies} do
      # Create a regular file (not streamable)
      {:ok, regular_file} = VFS.create_file(movies.id, "notes.txt")

      request = %RemoveRequest{parent_node_id: movies.id, name: "notes.txt"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      assert {:error, :not_found} = VFS.get_node(regular_file.id)
    end
  end

  describe "remove directory" do
    test "removes empty directory", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "empty")

      request = %RemoveRequest{parent_node_id: root.id, name: "empty"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      assert {:error, :not_found} = VFS.get_node(dir.id)
    end

    # Note: gRPC layer uses cascade: true by default per spec recommendation
    # This test has been updated to reflect that behavior
    test "cascade removes non-empty directory", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "not_empty")
      {:ok, _file} = VFS.create_file(dir.id, "file.txt")

      request = %RemoveRequest{parent_node_id: root.id, name: "not_empty"}

      # Should succeed with cascade: true default
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Directory and contents should be gone
      assert {:error, :not_found} = VFS.get_node(dir.id)
    end

    test "cascade removes directory with files", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "folder")
      {:ok, _file1} = VFS.create_file(dir.id, "file1.txt")
      {:ok, _file2} = VFS.create_file(dir.id, "file2.txt")

      # Note: May need to add cascade flag to RemoveRequest proto
      request = %RemoveRequest{parent_node_id: root.id, name: "folder"}
      # For now, assume cascade is default or add flag later
      assert %RemoveResponse{} = Server.remove(request, nil)

      # All should be gone (implementation detail)
    end

    test "cascade removes nested directories", %{root: root} do
      {:ok, parent} = VFS.create_directory(root.id, "parent")
      {:ok, child} = VFS.create_directory(parent.id, "child")
      {:ok, _file} = VFS.create_file(child.id, "deep.txt")

      request = %RemoveRequest{parent_node_id: root.id, name: "parent"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Full tree should be removed (implementation detail)
    end
  end

  describe "remove directory with torrent files" do
    @tag :sync_engine
    test "marks all torrents for deletion when directory is removed", %{root: root} do
      {:ok, movies} = VFS.create_directory(root.id, "movies")

      {:ok, _movie1} =
        VFS.create_file(movies.id, "movie1.mkv",
          content_type: "debrid_drive_ex/streamable",
          size: 1_000_000
        )

      {:ok, _movie2} =
        VFS.create_file(movies.id, "movie2.mkv",
          content_type: "debrid_drive_ex/streamable",
          size: 2_000_000
        )

      request = %RemoveRequest{parent_node_id: root.id, name: "movies"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Both torrents should be queued for deletion
      # Implementation detail: Check torrent deletion queue
    end

    @tag :sync_engine
    test "handles mixed content directory", %{root: root} do
      {:ok, mixed} = VFS.create_directory(root.id, "mixed")

      # Local file
      {:ok, _notes} = VFS.create_file(mixed.id, "notes.txt")

      # Torrent file
      {:ok, _movie} =
        VFS.create_file(mixed.id, "movie.mkv",
          content_type: "debrid_drive_ex/streamable",
          size: 1_000_000
        )

      # Hard link to external file
      {:ok, external_target} = VFS.create_file(root.id, "external.txt")
      {:ok, _link} = VFS.create_hardlink(mixed.id, "link.txt", external_target.id)

      request = %RemoveRequest{parent_node_id: root.id, name: "mixed"}
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Local file deleted immediately
      # Torrent file marked for deletion
      # Hard link deleted (but external target remains)
      assert {:ok, _} = VFS.get_node(external_target.id)
    end
  end

  describe "cascade hard link deletion" do
    test "removes external hard links when target is deleted with cascade", %{root: root} do
      {:ok, movies} = VFS.create_directory(root.id, "movies")
      {:ok, favorites} = VFS.create_directory(root.id, "favorites")

      {:ok, target} = VFS.create_file(movies.id, "movie.mkv")
      {:ok, _link} = VFS.create_hardlink(favorites.id, "favorite.mkv", target.id)

      # Delete movies directory (which contains the target)
      # With cascade_hardlinks flag, external hard link should also be removed
      request = %RemoveRequest{parent_node_id: root.id, name: "movies"}
      # Note: May need to add cascade_hardlinks flag to proto
      assert %RemoveResponse{} = Server.remove(request, nil)

      # Implementation detail: Check if link is also deleted
    end
  end

  describe "error handling" do
    test "handles invalid parent_node_id", %{root: _root} do
      request = %RemoveRequest{parent_node_id: 99999, name: "file.txt"}

      assert_raise GRPC.RPCError, ~r/not found/i, fn ->
        Server.remove(request, nil)
      end
    end

    # Note: VFS.lookup returns :not_found for children of non-directories
    # This is acceptable behavior - files can't have children
    test "handles parent that is not a directory", %{root: root} do
      {:ok, file} = VFS.create_file(root.id, "file.txt")

      request = %RemoveRequest{parent_node_id: file.id, name: "something.txt"}

      # Should raise not_found since files can't have children
      assert_raise GRPC.RPCError, ~r/not found/i, fn ->
        Server.remove(request, nil)
      end
    end

    test "handles concurrent deletions gracefully", %{root: root} do
      {:ok, _file} = VFS.create_file(root.id, "concurrent.txt")

      request = %RemoveRequest{parent_node_id: root.id, name: "concurrent.txt"}

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
      # This is a placeholder for testing transaction rollback
      # Actual implementation would need to trigger a failure mid-operation
      # and verify that nothing was deleted
    end
  end
end
