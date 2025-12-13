defmodule VFSTest do
  use ExUnit.Case, async: false

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

  describe "FileMode" do
    test "directory_mode creates correct mode" do
      mode = FileMode.directory_mode()
      assert FileMode.dir?(mode)
      assert FileMode.permissions(mode) == 0o755
    end

    test "file_mode creates correct mode" do
      mode = FileMode.file_mode()
      assert FileMode.regular?(mode)
      assert FileMode.permissions(mode) == 0o644
    end

    test "symlink_mode creates correct mode" do
      mode = FileMode.symlink_mode()
      assert FileMode.symlink?(mode)
    end

    test "custom permissions are preserved" do
      mode = FileMode.directory_mode(0o700)
      assert FileMode.dir?(mode)
      assert FileMode.permissions(mode) == 0o700
    end

    test "identifies 0o40755 as directory" do
      mode = 0o40755
      assert FileMode.dir?(mode)
      assert FileMode.permissions(mode) == 0o755
    end
  end

  describe "tree operations" do
    test "creates nested directory structure", %{root: root} do
      {:ok, folder_a} = VFS.create_directory(root.inode_id, "folder_a")
      {:ok, folder_b} = VFS.create_directory(root.inode_id, "folder_b")
      {:ok, sub_folder} = VFS.create_directory(folder_a.inode_id, "sub_folder")

      assert FileMode.dir?(folder_a.mode)
      assert FileMode.dir?(folder_b.mode)
      assert FileMode.dir?(sub_folder.mode)

      children = VFS.list_children(root.inode_id)
      assert length(children) == 2
      # list_children returns {entry, inode} tuples
      assert Enum.any?(children, fn {entry, _inode} -> entry.name == "folder_a" end)
      assert Enum.any?(children, fn {entry, _inode} -> entry.name == "folder_b" end)

      sub_children = VFS.list_children(folder_a.inode_id)
      assert length(sub_children) == 1
      {entry, _inode} = hd(sub_children)
      assert entry.name == "sub_folder"
    end

    test "moves file from folder A to folder B", %{root: root} do
      {:ok, folder_a} = VFS.create_directory(root.inode_id, "folder_a")
      {:ok, folder_b} = VFS.create_directory(root.inode_id, "folder_b")
      {:ok, file} = VFS.create_file(folder_a.inode_id, "test.txt")

      # Verify file is in folder_a
      assert {:ok, ^file} = VFS.lookup(folder_a.inode_id, "test.txt")

      # Move file to folder_b - new signature: move(old_parent, old_name, new_parent, new_name)
      {:ok, _result} = VFS.move(folder_a.inode_id, "test.txt", folder_b.inode_id, "test.txt")

      # Verify file is now in folder_b
      assert {:ok, found} = VFS.lookup(folder_b.inode_id, "test.txt")
      assert found.inode_id == file.inode_id

      # Verify file is not in folder_a anymore
      assert {:error, :not_found} = VFS.lookup(folder_a.inode_id, "test.txt")
    end

    test "renames a file", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "old_name.txt")

      {:ok, _result} = VFS.move(root.inode_id, "old_name.txt", root.inode_id, "new_name.txt")

      assert {:error, :not_found} = VFS.lookup(root.inode_id, "old_name.txt")
      assert {:ok, found} = VFS.lookup(root.inode_id, "new_name.txt")
      assert found.inode_id == file.inode_id
    end

    test "deletes a directory", %{root: root} do
      {:ok, _folder} = VFS.create_directory(root.inode_id, "to_delete")

      :ok = VFS.remove(root.inode_id, "to_delete")

      assert {:error, :not_found} = VFS.lookup(root.inode_id, "to_delete")
    end

    test "delete cascades to children", %{root: root} do
      {:ok, folder} = VFS.create_directory(root.inode_id, "parent")
      {:ok, child} = VFS.create_directory(folder.inode_id, "child")
      {:ok, _file} = VFS.create_file(child.inode_id, "file.txt")

      :ok = VFS.remove(root.inode_id, "parent")

      assert {:error, :not_found} = VFS.lookup(root.inode_id, "parent")
      # Child should also be gone due to cascade
      assert {:error, :not_found} = VFS.get_node(child.inode_id)
    end
  end

  describe "I/O operations" do
    test "writes and reads string data", %{root: root} do
      content = "Hello, World!"
      {:ok, file} = VFS.create_file(root.inode_id, "test.txt", data: content)

      {:ok, read_data} = VFS.read_data(file.inode_id)
      assert read_data == content
      assert file.size == byte_size(content)
    end

    test "writes data at offset", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "test.txt", data: "Hello")

      {:ok, updated} = VFS.write_data(file.inode_id, " World", 5)

      {:ok, data} = VFS.read_data(file.inode_id)
      assert data == "Hello World"
      assert updated.size == byte_size("Hello World")
    end

    test "reads with offset and size", %{root: root} do
      content = "Hello, World!"
      {:ok, file} = VFS.create_file(root.inode_id, "test.txt", data: content)

      {:ok, data} = VFS.read_data(file.inode_id, 7, 5)
      assert data == "World"
    end

    test "writes binary data", %{root: root} do
      binary = <<1, 2, 3, 4, 5>>
      {:ok, file} = VFS.create_file(root.inode_id, "binary.dat", data: binary)

      {:ok, read_data} = VFS.read_data(file.inode_id)
      assert read_data == binary
    end

    test "overwrites existing data", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "test.txt", data: "Original")

      {:ok, _} = VFS.write_data(file.inode_id, "Modified")

      {:ok, data} = VFS.read_data(file.inode_id)
      assert data == "Modified"
    end
  end

  describe "lookup operations" do
    test "looks up child by name", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "find_me.txt")

      {:ok, found} = VFS.lookup(root.inode_id, "find_me.txt")
      assert found.inode_id == file.inode_id
    end

    test "returns error for non-existent child", %{root: root} do
      assert {:error, :not_found} = VFS.lookup(root.inode_id, "does_not_exist.txt")
    end
  end

  describe "node attributes" do
    test "file has correct content_type", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "test.json", content_type: "application/json")

      assert file.content_type == "application/json"
    end

    test "updates node attributes", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "test.txt")

      {:ok, updated} = VFS.update_node(file.inode_id, %{content_type: "text/plain"})

      assert updated.content_type == "text/plain"
    end
  end
end
