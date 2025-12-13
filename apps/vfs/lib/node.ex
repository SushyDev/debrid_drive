defmodule VFS.Node do
  use Ecto.Schema
  import Ecto.Changeset
  alias VFS.FileMode

  schema "nodes" do
    field(:name, :string)
    field(:mode, :integer)
    field(:content_type, :string)
    field(:size, :integer, default: 0)
    field(:data, :binary)
    field(:is_hardlink, :boolean, default: false)
    # Explicit hardlink target columns
    field(:hardlink_target_node_id, :integer)
    field(:hardlink_target_torrent_file_id, :integer)

    belongs_to(:parent, __MODULE__, foreign_key: :parent_id)
    has_many(:children, __MODULE__, foreign_key: :parent_id)

    timestamps()
  end

  @doc false
  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :parent_id,
      :name,
      :mode,
      :content_type,
      :size,
      :data,
      :is_hardlink,
      :hardlink_target_node_id,
      :hardlink_target_torrent_file_id
    ])
    |> validate_required([:name, :mode])
    |> validate_name()
    |> validate_size()
    |> validate_mode()
    |> validate_not_self_parent()
    |> validate_file_has_no_children()
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint([:parent_id, :name])
  end

  # Validates that name is not empty and doesn't contain path separators
  # Exception: root node can be named "/"
  defp validate_name(changeset) do
    name = get_field(changeset, :name)
    parent_id = get_field(changeset, :parent_id)

    changeset
    |> validate_length(:name, min: 1, max: 255)
    |> then(fn cs ->
      # Allow "/" only for root node (parent_id is nil)
      if name == "/" && is_nil(parent_id) do
        cs
      else
        validate_format(cs, :name, ~r/^[^\/\0]+$/, message: "cannot contain / or null bytes")
      end
    end)
  end

  # Validates that size is non-negative
  defp validate_size(changeset) do
    validate_number(changeset, :size, greater_than_or_equal_to: 0)
  end

  # Validates that mode is a valid Unix mode
  defp validate_mode(changeset) do
    validate_number(changeset, :mode, greater_than: 0, less_than: 0o170000)
  end

  # Validates that a node cannot be its own parent
  defp validate_not_self_parent(changeset) do
    node_id = changeset.data.id
    parent_id = get_change(changeset, :parent_id)

    if node_id && parent_id && node_id == parent_id do
      add_error(changeset, :parent_id, "node cannot be its own parent")
    else
      changeset
    end
  end

  # Validates that regular files cannot have children
  # This is enforced at the application level since we can't easily check children in changeset
  defp validate_file_has_no_children(changeset) do
    mode = get_field(changeset, :mode)
    node_id = changeset.data.id

    # Only validate if we have a mode and this is an existing node being updated
    if mode && node_id && !FileMode.dir?(mode) do
      # Check if this node has children
      case count_children(node_id) do
        count when count > 0 ->
          add_error(
            changeset,
            :mode,
            "cannot change directory to file when it has children"
          )

        _ ->
          changeset
      end
    else
      changeset
    end
  end

  # Helper to count children (used in validation)
  defp count_children(node_id) do
    import Ecto.Query
    alias VFS.Repo

    Repo.one(
      from(node in __MODULE__,
        where: node.parent_id == ^node_id,
        select: count(node.id)
      )
    ) || 0
  end
end
