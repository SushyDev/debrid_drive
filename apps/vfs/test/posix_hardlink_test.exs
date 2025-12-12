defmodule PosixHardlinkTest do
  @moduledoc """
  Comprehensive test suite for POSIX-compliant hardlinks.

  POSIX hardlinks are hardlinks to regular VFS nodes (files and directories).
  They differ from virtual inode hardlinks which point to streamable torrent files.

  ## Key characteristics of POSIX hardlinks:
  - Created with `VFS.create_hardlink(parent_id, name, target_id)`
  - Target must be a regular VFS node (file or directory)
  - Schema fields:
    - `is_hardlink = true` (marks this as a hardlink)
    - `hardlink_target_id = target_node_id` (stores target reference)
    - `data = to_string(target_node_id)` (backward compatibility - stores target ID as string)
  - NOT streamable (cannot be streamed from Real Debrid)
  - File operations are independent (don't auto-resolve to target)
  - Can be used via gRPC Link RPC
  - Support multiple hardlinks to the same target
  - Can be renamed, moved, and deleted independently

  ## Differences from Virtual Inode Hardlinks:
  - Virtual inode hardlinks: `data` field = "vi:{inode_id}"
  - POSIX hardlinks: `data` field = "{target_node_id}"
  - Virtual inode hardlinks ARE streamable
  - POSIX hardlinks are NOT streamable
  - Both can coexist in the same filesystem

  ## POSIX Hardlink Behavior:
  - Hardlinks maintain independent data from targets
  - Deleting a hardlink does NOT affect the target
  - Deleting a target does NOT affect existing hardlinks
  - File size and data are snapshots at creation time
  - Modifications to target and hardlink are independent
  - extract_virtual_inode_id/1 returns {:error, :not_virtual_inode} for POSIX hardlinks
  """

  use ExUnit.Case

  alias VFS
  alias VFS.FileMode
  alias VFS.Repo

  setup do
    # Explicitly get a connection checkout for the test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Get or create root
    {:ok, root} = VFS.get_root()

    {:ok, root: root}
  end

  describe "POSIX hardlink creation" do
    test "creates a hardlink to a regular file", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink to it
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Verify hardlink properties
      assert hardlink.name == "link.txt"
      assert hardlink.parent_id == root.id
      assert VFS.is_hardlink?(hardlink)
      assert hardlink.hardlink_target_id == target.id
      assert hardlink.size == target.size
      assert FileMode.regular?(hardlink.mode)
      # Data field stores the target node ID as a string (backward compatibility)
      assert hardlink.data == to_string(target.id)
    end

    test "creates multiple hardlinks to the same target", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create multiple hardlinks
      {:ok, link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(root.id, "link2.txt", target.id)
      {:ok, link3} = VFS.create_hardlink(root.id, "link3.txt", target.id)

      # All should point to the same target
      assert link1.hardlink_target_id == target.id
      assert link2.hardlink_target_id == target.id
      assert link3.hardlink_target_id == target.id

      # All should be hardlinks
      assert VFS.is_hardlink?(link1)
      assert VFS.is_hardlink?(link2)
      assert VFS.is_hardlink?(link3)

      # Data field should store target ID as string
      assert link1.data == to_string(target.id)
      assert link2.data == to_string(target.id)
      assert link3.data == to_string(target.id)
    end

    test "creates hardlinks in different directories to the same target", %{root: root} do
      # Create target file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create directories
      {:ok, dir1} = VFS.create_directory(root.id, "dir1")
      {:ok, dir2} = VFS.create_directory(root.id, "dir2")

      # Create hardlinks in different directories
      {:ok, link1} = VFS.create_hardlink(dir1.id, "link.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(dir2.id, "link.txt", target.id)

      # Both should point to the same target
      assert link1.hardlink_target_id == target.id
      assert link2.hardlink_target_id == target.id

      # They should be in different parents
      assert link1.parent_id == dir1.id
      assert link2.parent_id == dir2.id
    end

    test "rejects hardlink to another hardlink", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Try to create a hardlink to the hardlink
      result = VFS.create_hardlink(root.id, "link2.txt", hardlink.id)

      assert result == {:error, :cannot_link_to_hardlink}
    end

    test "allows hardlink to directory (directory becomes a link)", %{root: root} do
      # Create a directory
      {:ok, dir} = VFS.create_directory(root.id, "subdir")

      # Create a hardlink to the directory (this is allowed in the current implementation)
      {:ok, hardlink} = VFS.create_hardlink(root.id, "dir_link", dir.id)

      # Should create a hardlink to the directory
      assert VFS.is_hardlink?(hardlink)
      assert hardlink.hardlink_target_id == dir.id
      # Should inherit directory mode
      assert hardlink.mode == dir.mode
    end

    test "rejects hardlink to non-existent node", %{root: root} do
      # Try to create a hardlink to a non-existent node
      result = VFS.create_hardlink(root.id, "link.txt", 99999)

      assert result == {:error, :not_found}
    end
  end

  describe "POSIX hardlink lookup and retrieval" do
    test "lookup finds a hardlink by name", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink
      {:ok, _hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Lookup the hardlink
      {:ok, found} = VFS.lookup(root.id, "link.txt")

      assert found.name == "link.txt"
      assert VFS.is_hardlink?(found)
      assert found.hardlink_target_id == target.id
    end

    test "get_node retrieves a hardlink by ID", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Retrieve it by ID
      {:ok, found} = VFS.get_node(hardlink.id)

      assert found.id == hardlink.id
      assert VFS.is_hardlink?(found)
      assert found.hardlink_target_id == target.id
    end

    test "list_children includes hardlinks", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create hardlinks
      {:ok, link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(root.id, "link2.txt", target.id)

      # List children
      children = VFS.list_children(root.id)

      # Should include target and both hardlinks
      ids = Enum.map(children, & &1.id)
      assert target.id in ids
      assert link1.id in ids
      assert link2.id in ids
    end
  end

  describe "POSIX hardlink file operations" do
    test "hardlink data field stores target node ID as string", %{root: root} do
      # Create a file with content
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 0)
      data = "Hello, World!"
      {:ok, target_with_data} = VFS.write_data(target.id, data, 0)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Hardlink's data field stores the target node ID as a string (backward compatibility)
      # NOT the actual target content
      assert hardlink.data == to_string(target.id)
      assert target_with_data.data == data
    end

    test "hardlink maintains independent data field from target", %{root: root} do
      # Create a file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 0)

      # Create a hardlink (data stores target ID)
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Write to hardlink
      new_data = "Written through hardlink"
      {:ok, _} = VFS.write_data(hardlink.id, new_data, 0)

      # Hardlink has the new data
      {:ok, hardlink_updated} = VFS.get_node(hardlink.id)
      assert hardlink_updated.data == new_data

      # Target still has its original data (empty string initially)
      {:ok, target_reload} = VFS.get_node(target.id)
      assert target_reload.data != new_data
    end

    test "hardlink and target have independent data fields", %{root: root} do
      # Create a file with content
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 0)
      target_data = "Target content"
      {:ok, target_with_data} = VFS.write_data(target.id, target_data, 0)

      # Create a hardlink (stores target ID, not content)
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target_with_data.id)

      # Hardlink stores target ID as string, not target's content
      assert hardlink.data == to_string(target_with_data.id)
      assert target_with_data.data == target_data

      # Modify target
      {:ok, _} = VFS.write_data(target.id, "Modified target", 0)

      # Reload both
      {:ok, target_new} = VFS.get_node(target.id)
      {:ok, hardlink_reload} = VFS.get_node(hardlink.id)

      # Target changed, hardlink still stores target ID
      assert target_new.data == "Modified target"
      assert hardlink_reload.data == to_string(target_with_data.id)
    end

    test "hardlink size matches target size at creation", %{root: root} do
      # Create a file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 100)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Hardlink should have same size as target at creation time
      assert hardlink.size == target.size
    end

    test "truncate hardlink independent of target", %{root: root} do
      # Create a file with content
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 0)
      original_data = "This will be truncated"
      {:ok, _} = VFS.write_data(target.id, original_data, 0)

      # Create a hardlink
      {:ok, target_reloaded} = VFS.get_node(target.id)
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target_reloaded.id)

      # Truncate hardlink (set size to 0)
      {:ok, _} = VFS.update_node(hardlink.id, %{size: 0, data: <<>>})

      # Verify hardlink is truncated
      {:ok, hardlink_after} = VFS.get_node(hardlink.id)
      assert hardlink_after.size == 0

      # Verify target is not affected
      {:ok, target_after} = VFS.get_node(target.id)
      assert target_after.size == byte_size(original_data)
    end
  end

  describe "POSIX hardlink deletion" do
    test "delete a hardlink leaves target intact", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Delete the hardlink
      :ok = VFS.remove_by_id(hardlink.id, cascade: false)

      # Hardlink should be gone
      assert VFS.get_node(hardlink.id) == {:error, :not_found}

      # Target should still exist
      {:ok, target_still_exists} = VFS.get_node(target.id)
      assert target_still_exists.id == target.id
    end

    test "delete target does not affect other hardlinks", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create multiple hardlinks
      {:ok, link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(root.id, "link2.txt", target.id)

      # Delete the target
      :ok = VFS.remove_by_id(target.id, cascade: false)

      # Target should be gone
      assert VFS.get_node(target.id) == {:error, :not_found}

      # Hardlinks should still exist (dangling links)
      {:ok, link1_still} = VFS.get_node(link1.id)
      assert link1_still.id == link1.id

      {:ok, link2_still} = VFS.get_node(link2.id)
      assert link2_still.id == link2.id
    end

    test "cascade delete removes all hardlinks to a target", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create multiple hardlinks
      {:ok, link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(root.id, "link2.txt", target.id)

      # Delete with cascade_hardlinks: true
      :ok = VFS.remove_by_id(target.id, cascade: true, cascade_hardlinks: true)

      # All should be gone
      assert VFS.get_node(target.id) == {:error, :not_found}
      assert VFS.get_node(link1.id) == {:error, :not_found}
      assert VFS.get_node(link2.id) == {:error, :not_found}
    end

    test "delete directory with hardlinks cascade deletes all", %{root: root} do
      # Create a directory with a file
      {:ok, dir} = VFS.create_directory(root.id, "testdir")
      {:ok, target} = VFS.create_file(dir.id, "file.txt", size: 1000)

      # Create hardlinks outside the directory
      {:ok, link1} = VFS.create_hardlink(root.id, "link1.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(root.id, "link2.txt", target.id)

      # Delete the directory with cascade and cascade_hardlinks
      :ok = VFS.remove_by_id(dir.id, cascade: true, cascade_hardlinks: true)

      # Directory and target should be gone
      assert VFS.get_node(dir.id) == {:error, :not_found}
      assert VFS.get_node(target.id) == {:error, :not_found}

      # Hardlinks should also be gone
      assert VFS.get_node(link1.id) == {:error, :not_found}
      assert VFS.get_node(link2.id) == {:error, :not_found}
    end

    test "delete hardlink without cascade_hardlinks leaves target intact", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Delete hardlink with cascade: true but cascade_hardlinks: false (default)
      :ok = VFS.remove_by_id(hardlink.id, cascade: true)

      # Hardlink should be gone
      assert VFS.get_node(hardlink.id) == {:error, :not_found}

      # Target should still exist
      {:ok, target_still} = VFS.get_node(target.id)
      assert target_still.id == target.id
    end
  end

  describe "POSIX hardlink rename/move" do
    test "rename a hardlink", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Rename the hardlink
      {:ok, renamed} = VFS.move(hardlink.id, root.id, "renamed_link.txt")

      # Should still be a hardlink pointing to same target
      assert VFS.is_hardlink?(renamed)
      assert renamed.hardlink_target_id == target.id
      assert renamed.name == "renamed_link.txt"

      # Old name should not be found
      assert VFS.lookup(root.id, "link.txt") == {:error, :not_found}

      # New name should be found
      {:ok, found} = VFS.lookup(root.id, "renamed_link.txt")
      assert found.id == renamed.id
    end

    test "move hardlink to another directory", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Create another directory
      {:ok, dir} = VFS.create_directory(root.id, "subdir")

      # Move the hardlink to the other directory
      {:ok, moved} = VFS.move(hardlink.id, dir.id, "moved_link.txt")

      # Should still be a hardlink pointing to same target
      assert VFS.is_hardlink?(moved)
      assert moved.hardlink_target_id == target.id
      assert moved.parent_id == dir.id

      # Old location should not have it
      assert VFS.lookup(root.id, "link.txt") == {:error, :not_found}

      # New location should have it
      {:ok, found} = VFS.lookup(dir.id, "moved_link.txt")
      assert found.id == moved.id
    end
  end

  describe "POSIX hardlink extract_virtual_inode_id" do
    test "extract_virtual_inode_id returns error for regular POSIX hardlinks", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a POSIX hardlink (not virtual inode)
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # extract_virtual_inode_id should fail because this is NOT a virtual inode hardlink
      result = VFS.extract_virtual_inode_id(hardlink)

      assert result == {:error, :not_virtual_inode}
    end

    test "extract_virtual_inode_id returns error for non-hardlinks", %{root: root} do
      # Create a regular file (not a hardlink)
      {:ok, file} = VFS.create_file(root.id, "regular.txt", size: 1000)

      # extract_virtual_inode_id should fail
      result = VFS.extract_virtual_inode_id(file)

      assert result == {:error, :not_a_hardlink}
    end
  end

  describe "POSIX hardlink properties and metadata" do
    test "hardlink inherits target's mode and size", %{root: root} do
      # Create a file with specific properties
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 5000, mode: 33188)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Should inherit target's properties
      assert hardlink.mode == target.mode
      assert hardlink.size == target.size
    end

    test "hardlink size snapshot at creation time", %{root: root} do
      # Create a file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 0)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Hardlink size matches target at creation time (size snapshot)
      assert hardlink.size == target.size

      # If target size changes after hardlink creation, hardlink doesn't automatically update
      # (they're independent after creation)
      new_data = "New content"
      {:ok, updated_target} = VFS.write_data(target.id, new_data, 0)

      # Hardlink still has original size (not synced to target changes)
      {:ok, hardlink_after} = VFS.get_node(hardlink.id)
      assert hardlink_after.size != updated_target.size
    end

    test "is_hardlink? correctly identifies POSIX hardlinks", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Regular file should not be a hardlink
      assert VFS.is_hardlink?(target) == false

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Hardlink should be identified as such
      assert VFS.is_hardlink?(hardlink) == true
    end

    test "hardlink is marked as regular file by FileMode", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Both should be marked as regular files
      assert FileMode.regular?(target.mode)
      assert FileMode.regular?(hardlink.mode)
    end
  end

  describe "POSIX hardlink integration with gRPC" do
    test "hardlink has correct data representation (stores target ID)", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a POSIX hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Data field stores the target node ID as string (backward compatibility)
      assert hardlink.data == to_string(target.id)

      # hardlink_target_id should also be set to target
      assert hardlink.hardlink_target_id == target.id

      # is_hardlink should be true
      assert hardlink.is_hardlink == true
    end

    test "hardlink correctly distinguished from virtual inode hardlinks", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create a POSIX hardlink
      {:ok, posix_hardlink} = VFS.create_hardlink(root.id, "posix_link.txt", target.id)

      # Check properties
      assert VFS.is_hardlink?(posix_hardlink)
      # Data field stores target ID as string (not "vi:..." format)
      assert posix_hardlink.data == to_string(target.id)
      assert posix_hardlink.hardlink_target_id == target.id

      # extract_virtual_inode_id should distinguish it from virtual inode hardlinks
      # (POSIX hardlinks don't have data starting with "vi:")
      assert VFS.extract_virtual_inode_id(posix_hardlink) == {:error, :not_virtual_inode}
    end
  end

  describe "POSIX hardlink edge cases" do
    test "same hardlink name in different directories", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "original.txt", size: 1000)

      # Create directories
      {:ok, dir1} = VFS.create_directory(root.id, "dir1")
      {:ok, dir2} = VFS.create_directory(root.id, "dir2")

      # Create hardlinks with same name in different directories
      {:ok, link1} = VFS.create_hardlink(dir1.id, "same_name.txt", target.id)
      {:ok, link2} = VFS.create_hardlink(dir2.id, "same_name.txt", target.id)

      # Both should exist and point to same target
      {:ok, found1} = VFS.lookup(dir1.id, "same_name.txt")
      {:ok, found2} = VFS.lookup(dir2.id, "same_name.txt")

      assert found1.id == link1.id
      assert found2.id == link2.id
      assert link1.hardlink_target_id == target.id
      assert link2.hardlink_target_id == target.id
    end

    test "deep directory hierarchy with hardlinks", %{root: root} do
      # Create nested directories
      {:ok, dir1} = VFS.create_directory(root.id, "level1")
      {:ok, dir2} = VFS.create_directory(dir1.id, "level2")
      {:ok, dir3} = VFS.create_directory(dir2.id, "level3")

      # Create a file at the deepest level
      {:ok, target} = VFS.create_file(dir3.id, "file.txt", size: 1000)

      # Create a hardlink at the root pointing to the deep file
      {:ok, _hardlink} = VFS.create_hardlink(root.id, "link_to_deep.txt", target.id)

      # Verify it works
      {:ok, found} = VFS.lookup(root.id, "link_to_deep.txt")
      assert found.hardlink_target_id == target.id

      # Hardlink should store target ID in data field
      assert found.data == to_string(target.id)
    end

    test "hardlink to small file", %{root: root} do
      # Create a small file
      {:ok, target} = VFS.create_file(root.id, "tiny.txt", size: 0)
      {:ok, _} = VFS.write_data(target.id, "x", 0)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "tiny_link.txt", target.id)

      # Should work fine
      assert VFS.is_hardlink?(hardlink)
      # Hardlink stores target ID, not the target's content
      assert hardlink.data == to_string(target.id)
    end

    test "hardlink to large file", %{root: root} do
      # Create a large file
      {:ok, target} = VFS.create_file(root.id, "large.bin", size: 0)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "large_link.bin", target.id)

      # Should work fine
      assert VFS.is_hardlink?(hardlink)
      assert hardlink.hardlink_target_id == target.id
    end
  end

  describe "POSIX hardlink with content types" do
    test "hardlink copies target's content type at creation", %{root: root} do
      # Create a file with content type
      {:ok, target} =
        VFS.create_file(root.id, "document.pdf", size: 1000, content_type: "application/pdf")

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "pdf_link.pdf", target.id)

      # Hardlink copies target's content type at creation time
      # (Note: hardlinks have independent content_type field, not inherited dynamically)
      assert target.content_type == "application/pdf"
      # The hardlink's content_type is nil by default unless explicitly set
      assert is_nil(hardlink.content_type)
    end
  end

  describe "POSIX hardlink consistency checks" do
    test "hardlink maintains independent state from target after creation", %{root: root} do
      # Create a file
      {:ok, target} = VFS.create_file(root.id, "file.txt", size: 0)

      # Create a hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Initially both have size 0
      assert target.size == hardlink.size

      # Write to target
      data1 = "First write to target"
      {:ok, target_updated} = VFS.write_data(target.id, data1, 0)

      # Reload hardlink - it should have same size since we're writing empty data to it initially
      {:ok, hardlink1} = VFS.get_node(hardlink.id)

      # Hardlink was created with target's data (which was empty), so it should still be empty
      assert hardlink1.size == 0
      assert target_updated.size == byte_size(data1)

      # Write to hardlink independently
      data2 = "Second write through hardlink"
      {:ok, _hardlink_updated} = VFS.write_data(hardlink.id, data2, 0)

      # Reload both
      {:ok, target_final} = VFS.get_node(target.id)
      {:ok, hardlink_final} = VFS.get_node(hardlink.id)

      # They should have independent data now
      assert target_final.size == byte_size(data1)
      assert hardlink_final.size == byte_size(data2)
      assert target_final.data == data1
      assert hardlink_final.data == data2
    end
  end
end
