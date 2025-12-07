defmodule VFS.NodeTest do
  use ExUnit.Case, async: true

  alias VFS.Node
  alias VFS.FileMode
  alias VFS.Repo
  alias VFS

  setup do
    # Explicitly get a connection checkout for the test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Get or create root
    {:ok, root} = VFS.get_root()

    {:ok, root: root}
  end

  describe "changeset validations" do
    test "valid changeset passes all validations", %{root: root} do
      changeset =
        Node.changeset(%Node{}, %{
          parent_id: root.id,
          name: "test.txt",
          mode: FileMode.file_mode(),
          content_type: "text/plain",
          size: 0
        })

      assert changeset.valid?
    end

    test "requires name" do
      changeset =
        Node.changeset(%Node{}, %{
          mode: FileMode.file_mode()
        })

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires mode" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "test.txt"
        })

      refute changeset.valid?
      assert %{mode: ["can't be blank"]} = errors_on(changeset)
    end

    test "name must be at least 1 character" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "",
          mode: FileMode.file_mode()
        })

      refute changeset.valid?
      assert %{name: errors} = errors_on(changeset)
      # Empty string triggers both "can't be blank" and length validation
      assert "can't be blank" in errors || "should be at least 1 character(s)" in errors
    end

    test "name cannot be longer than 255 characters" do
      long_name = String.duplicate("a", 256)

      changeset =
        Node.changeset(%Node{}, %{
          name: long_name,
          mode: FileMode.file_mode()
        })

      refute changeset.valid?
      assert %{name: errors} = errors_on(changeset)
      assert "should be at most 255 character(s)" in errors
    end

    test "name cannot contain forward slash" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "invalid/name.txt",
          mode: FileMode.file_mode()
        })

      refute changeset.valid?
      assert %{name: errors} = errors_on(changeset)
      assert "cannot contain / or null bytes" in errors
    end

    test "name cannot contain null bytes" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "invalid\0name.txt",
          mode: FileMode.file_mode()
        })

      refute changeset.valid?
      assert %{name: errors} = errors_on(changeset)
      assert "cannot contain / or null bytes" in errors
    end

    test "size must be non-negative" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "test.txt",
          mode: FileMode.file_mode(),
          size: -1
        })

      refute changeset.valid?
      assert %{size: ["must be greater than or equal to 0"]} = errors_on(changeset)
    end

    test "size can be zero" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "test.txt",
          mode: FileMode.file_mode(),
          size: 0
        })

      assert changeset.valid?
    end

    test "mode must be positive" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "test.txt",
          mode: 0
        })

      refute changeset.valid?
      assert %{mode: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "mode must be less than 0o170000" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "test.txt",
          mode: 0o170000
        })

      refute changeset.valid?
      assert %{mode: ["must be less than 61440"]} = errors_on(changeset)
    end
  end

  describe "self-parent validation" do
    test "node cannot be its own parent", %{root: root} do
      {:ok, node} = VFS.create_file(root.id, "test.txt")

      changeset = Node.changeset(node, %{parent_id: node.id})

      refute changeset.valid?
      assert %{parent_id: ["node cannot be its own parent"]} = errors_on(changeset)
    end

    test "allows setting a different parent", %{root: root} do
      {:ok, dir1} = VFS.create_directory(root.id, "dir1")
      {:ok, node} = VFS.create_file(root.id, "test.txt")

      changeset = Node.changeset(node, %{parent_id: dir1.id})

      assert changeset.valid?
    end
  end

  describe "file with children validation" do
    test "cannot change directory to file when it has children", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "test_dir")
      {:ok, _child} = VFS.create_file(dir.id, "child.txt")

      # Try to change the directory to a file
      changeset = Node.changeset(dir, %{mode: FileMode.file_mode()})

      refute changeset.valid?
      assert %{mode: errors} = errors_on(changeset)
      assert "cannot change directory to file when it has children" in errors
    end

    test "can change empty directory to file", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.id, "empty_dir")

      # Try to change the empty directory to a file
      changeset = Node.changeset(dir, %{mode: FileMode.file_mode()})

      assert changeset.valid?
    end

    test "can change file to directory", %{root: root} do
      {:ok, file} = VFS.create_file(root.id, "test.txt")

      # Try to change the file to a directory
      changeset = Node.changeset(file, %{mode: FileMode.directory_mode()})

      assert changeset.valid?
    end
  end

  describe "unique constraint" do
    test "enforces unique name within parent", %{root: root} do
      {:ok, _file1} = VFS.create_file(root.id, "duplicate.txt")

      # Try to create another file with the same name
      result = VFS.create_file(root.id, "duplicate.txt")

      assert {:error, changeset} = result
      assert %{parent_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same name in different directories", %{root: root} do
      {:ok, dir1} = VFS.create_directory(root.id, "dir1")
      {:ok, dir2} = VFS.create_directory(root.id, "dir2")

      {:ok, _file1} = VFS.create_file(dir1.id, "same_name.txt")
      {:ok, _file2} = VFS.create_file(dir2.id, "same_name.txt")

      # Both should succeed
      assert {:ok, _} = VFS.lookup(dir1.id, "same_name.txt")
      assert {:ok, _} = VFS.lookup(dir2.id, "same_name.txt")
    end
  end

  # Helper function to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
