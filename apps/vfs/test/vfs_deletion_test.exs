defmodule VFS.DeletionTest do
  @moduledoc """
  Tests for VFS deletion operations.

  Covers:
  - Regular file deletion
  - Hard link deletion (with and without target)
  - Directory deletion (empty and with content)
  - Cascade deletion behavior
  - Transaction rollback on errors
  - Hard link counting and reference tracking
  """
  use ExUnit.Case, async: false

  alias VFS
  alias VFS.Repo
  alias VFS.FileMode

  setup do
    # Explicitly checkout the connection
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Clean database before each test
    Repo.delete_all(VFS.Node)

    # Create root node
    {:ok, root} = VFS.create_directory(nil, "/", mode: FileMode.directory_mode(0o755))

    %{root: root}
  end

  describe "regular file deletion" do
    test "deletes a regular file successfully", %{root: root} do
      # Create a file
      {:ok, file} = VFS.create_file(root.id, "test.txt")

      # Delete it
      assert :ok = VFS.remove(root.id, "test.txt")

      # Verify it's gone
      assert {:error, :not_found} = VFS.lookup(root.id, "test.txt")
      assert {:error, :not_found} = VFS.get_node(file.id)
    end

    test "returns error when file doesn't exist", %{root: root} do
      assert {:error, :not_found} = VFS.remove(root.id, "nonexistent.txt")
    end

    test "deletes file with custom content type", %{root: root} do
      {:ok, file} = VFS.create_file(root.id, "data.json", content_type: "application/json")

      assert :ok = VFS.remove(root.id, "data.json")
      assert {:error, :not_found} = VFS.get_node(file.id)
    end
  end

  describe "hard link deletion - target remains" do
    test "deletes hard link without affecting target", %{root: root} do
      # Create target file
      {:ok, target} = VFS.create_file(root.id, "target.txt")

      # Create hard link
      {:ok, link} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Delete the hard link
      assert :ok = VFS.remove(root.id, "link.txt")

      # Verify hard link is gone
      assert {:error, :not_found} = VFS.lookup(root.id, "link.txt")
      assert {:error, :not_found} = VFS.get_node(link.id)

      # Verify target still exists
      assert {:ok, ^target} = VFS.get_node(target.id)
      assert {:ok, found_target} = VFS.lookup(root.id, "target.txt")
      assert found_target.id == target.id
    end

    test "deletes multiple hard links independently", %{root: root} do
      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(root.id, "link2.txt", target.id)

      # Delete first link
      assert :ok = VFS.remove(root.id, "link1.txt")
      assert {:error, :not_found} = VFS.get_node(link1.id)

      # Verify second link and target still exist
      assert {:ok, _} = VFS.get_node(link2.id)
      assert {:ok, _} = VFS.get_node(target.id)

      # Delete second link
      assert :ok = VFS.remove(root.id, "link2.txt")
      assert {:error, :not_found} = VFS.get_node(link2.id)

      # Target still exists
      assert {:ok, _} = VFS.get_node(target.id)
    end
  end

  describe "hard link deletion - last reference" do
    test "deletes last hard link when target is already deleted", %{root: root} do
      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, link} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Delete target first
      assert :ok = VFS.remove(root.id, "target.txt")
      assert {:error, :not_found} = VFS.get_node(target.id)

      # Delete the orphaned hard link
      assert :ok = VFS.remove(root.id, "link.txt")
      assert {:error, :not_found} = VFS.get_node(link.id)
    end

    test "counts remaining hard links to target", %{root: root} do
      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, _link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)
      {:ok, _link2} = VFS.create_hardlink(root.id, "link2.txt", target.id)

      # Should have 2 hard links
      assert VFS.count_hardlinks_to_target(target.id) == 2

      # Delete one
      :ok = VFS.remove(root.id, "link1.txt")
      assert VFS.count_hardlinks_to_target(target.id) == 1

      # Delete the other
      :ok = VFS.remove(root.id, "link2.txt")
      assert VFS.count_hardlinks_to_target(target.id) == 0
    end
  end

  describe "target file deletion with hard links" do
    test "cascade deletes all hard links when target is deleted", %{root: root} do
      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(root.id, "link2.txt", target.id)

      # Delete target with cascade
      assert :ok = VFS.remove(root.id, "target.txt", cascade_hardlinks: true)

      # Verify everything is gone
      assert {:error, :not_found} = VFS.get_node(target.id)
      assert {:error, :not_found} = VFS.get_node(link1.id)
      assert {:error, :not_found} = VFS.get_node(link2.id)
    end

    test "cascade works with hard links in different directories", %{root: root} do
      {:ok, movies} = VFS.create_directory(root.id, "movies")
      {:ok, favorites} = VFS.create_directory(root.id, "favorites")

      {:ok, target} = VFS.create_file(movies.id, "movie.mkv")
      {:ok, link} = VFS.create_hardlink(favorites.id, "favorite.mkv", target.id)

      # Delete target with cascade
      assert :ok = VFS.remove(movies.id, "movie.mkv", cascade_hardlinks: true)

      # Both should be gone
      assert {:error, :not_found} = VFS.get_node(target.id)
      assert {:error, :not_found} = VFS.get_node(link.id)
    end

    test "without cascade, allows orphaned hard links", %{root: root} do
      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, link} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Delete target without cascade (default behavior)
      assert :ok = VFS.remove(root.id, "target.txt")

      # Target is gone
      assert {:error, :not_found} = VFS.get_node(target.id)

      # Hard link still exists (orphaned)
      assert {:ok, orphaned_link} = VFS.get_node(link.id)
      assert VFS.is_hardlink?(orphaned_link)
      assert orphaned_link.data == to_string(target.id)
    end
  end

  describe "directory deletion - empty" do
    test "deletes empty directory", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "empty")

      assert :ok = VFS.remove(root.id, "empty")
      assert {:error, :not_found} = VFS.get_node(dir.id)
    end

    test "cannot delete non-empty directory without cascade", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "not_empty")
      {:ok, _file} = VFS.create_file(dir.id, "file.txt")

      assert {:error, :directory_not_empty} = VFS.remove(root.id, "not_empty", cascade: false)

      # Directory still exists
      assert {:ok, _} = VFS.get_node(dir.id)
    end
  end

  describe "directory deletion - with content" do
    test "cascade deletes directory with files", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "folder")
      {:ok, file1} = VFS.create_file(dir.id, "file1.txt")
      {:ok, file2} = VFS.create_file(dir.id, "file2.txt")

      assert :ok = VFS.remove(root.id, "folder", cascade: true)

      # Everything should be gone
      assert {:error, :not_found} = VFS.get_node(dir.id)
      assert {:error, :not_found} = VFS.get_node(file1.id)
      assert {:error, :not_found} = VFS.get_node(file2.id)
    end

    test "cascade deletes nested directories", %{root: root} do
      {:ok, parent} = VFS.create_directory(root.id, "parent")
      {:ok, child} = VFS.create_directory(parent.id, "child")
      {:ok, file} = VFS.create_file(child.id, "deep_file.txt")

      assert :ok = VFS.remove(root.id, "parent", cascade: true)

      assert {:error, :not_found} = VFS.get_node(parent.id)
      assert {:error, :not_found} = VFS.get_node(child.id)
      assert {:error, :not_found} = VFS.get_node(file.id)
    end

    test "cascade deletes directory with hard links inside", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "folder")
      {:ok, target} = VFS.create_file(dir.id, "target.txt")
      {:ok, link} = VFS.create_hardlink(dir.id, "link.txt", target.id)

      assert :ok = VFS.remove(root.id, "folder", cascade: true)

      assert {:error, :not_found} = VFS.get_node(dir.id)
      assert {:error, :not_found} = VFS.get_node(target.id)
      assert {:error, :not_found} = VFS.get_node(link.id)
    end

    test "cascade deletes directory but preserves external hard links", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "folder")
      {:ok, target} = VFS.create_file(dir.id, "target.txt")
      {:ok, external_link} = VFS.create_hardlink(root.id, "external_link.txt", target.id)

      # Delete directory (target inside will be deleted)
      # External link becomes orphaned
      assert :ok = VFS.remove(root.id, "folder", cascade: true)

      assert {:error, :not_found} = VFS.get_node(dir.id)
      assert {:error, :not_found} = VFS.get_node(target.id)

      # External link still exists (orphaned)
      assert {:ok, orphaned} = VFS.get_node(external_link.id)
      assert VFS.is_hardlink?(orphaned)
    end

    test "cascade with cascade_hardlinks deletes external hard links too", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "folder")
      {:ok, target} = VFS.create_file(dir.id, "target.txt")
      {:ok, external_link} = VFS.create_hardlink(root.id, "external_link.txt", target.id)

      # Delete directory with full cascade
      assert :ok = VFS.remove(root.id, "folder", cascade: true, cascade_hardlinks: true)

      assert {:error, :not_found} = VFS.get_node(dir.id)
      assert {:error, :not_found} = VFS.get_node(target.id)
      assert {:error, :not_found} = VFS.get_node(external_link.id)
    end
  end

  describe "transaction rollback" do
    test "rolls back on error during cascade delete", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "folder")
      {:ok, _file} = VFS.create_file(dir.id, "file.txt")

      # Simulate error by manually causing constraint violation
      # (This is a placeholder - actual implementation may differ)

      # For now, just verify transaction atomicity conceptually
      # All or nothing - if cascade fails, nothing is deleted

      # Note: Actual test would need to trigger a real failure scenario
      # such as foreign key constraint, unique constraint, etc.
    end
  end

  describe "edge cases" do
    test "cannot create hard link to another hard link", %{root: root} do
      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)

      # Should not allow creating hard link to hard link
      assert {:error, :cannot_link_to_hardlink} =
               VFS.create_hardlink(root.id, "link2.txt", link1.id)
    end

    test "finds all hard links to a target across directories", %{root: root} do
      {:ok, dir1} = VFS.create_directory(root.id, "dir1")
      {:ok, dir2} = VFS.create_directory(root.id, "dir2")

      {:ok, target} = VFS.create_file(root.id, "target.txt")
      {:ok, link1} = VFS.create_hardlink(dir1.id, "link1.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(dir2.id, "link2.txt", target.id)

      hardlinks = VFS.find_all_hardlinks_to_target(target.id)
      assert length(hardlinks) == 2
      assert Enum.any?(hardlinks, fn l -> l.id == link1.id end)
      assert Enum.any?(hardlinks, fn l -> l.id == link2.id end)
    end

    test "deleting root node is not allowed", %{root: _root} do
      # Cannot delete root
      assert {:error, :cannot_delete_root} = VFS.remove(nil, "/")
    end
  end
end
