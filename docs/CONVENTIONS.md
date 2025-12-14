# Code Conventions

**Debrid Drive Ex Coding Standards**

This document defines coding conventions and return type patterns for maintaining consistency across the Debrid Drive Ex umbrella project.

---

## Table of Contents

1. [Return Type Patterns](#return-type-patterns)
2. [Error Handling](#error-handling)
3. [Transaction Handling](#transaction-handling)
4. [Type Specifications](#type-specifications)
5. [Naming Conventions](#naming-conventions)
6. [Code Examples](#code-examples)

---

## Return Type Patterns

All public API functions MUST follow these standardized return patterns based on operation type.

### 1. Create Operations

**Pattern**: `{:ok, resource} | {:error, changeset}`

**When to use**: Functions that create new database records or resources.

**Examples**:
```elixir
def create_torrent(attrs) do
  %Torrent{}
  |> Torrent.changeset(attrs)
  |> Repo.insert()
end
# Returns: {:ok, %Torrent{}} | {:error, %Ecto.Changeset{}}

def create_directory(parent_id, name, opts \\ []) do
  Repo.transact(fn ->
    # ... creation logic
    inode
  end)
end
# Returns: {:ok, %Inode{}} | {:error, reason}
```

**Rationale**: Callers need the created resource for further operations (linking, referencing, etc.).

---

### 2. Update Operations

**Pattern**: `{:ok, resource} | {:error, changeset}`

**When to use**: Functions that modify existing database records.

**Examples**:
```elixir
def update_torrent(%Torrent{} = torrent, attrs) do
  torrent
  |> Torrent.changeset(attrs)
  |> Repo.update()
end
# Returns: {:ok, %Torrent{}} | {:error, %Ecto.Changeset{}}

def update_node(inode_id, attrs) do
  inode = Repo.get!(Inode, inode_id)
  
  inode
  |> Inode.changeset(attrs)
  |> Repo.update()
end
# Returns: {:ok, %Inode{}} | {:error, %Ecto.Changeset{}}
```

**Rationale**: Callers often need the updated resource to verify changes or use new values.

---

### 3. Delete Operations

**Pattern**: `:ok | {:error, reason}`

**When to use**: Functions that remove resources from the system.

**Examples**:
```elixir
def remove(parent_id, name, opts \\ []) do
  result =
    Repo.transact(fn ->
      # ... deletion logic
    end)

  case result do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
# Returns: :ok | {:error, :not_found} | {:error, :directory_not_empty}

def cleanup_after_deletion(torrent_id, opts \\ []) do
  Repo.transact(fn ->
    # ... cleanup logic
    :ok
  end)
  |> case do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
# Returns: :ok | {:error, reason}
```

**Rationale**: Deleted resources are gone; returning them has no value. Simple `:ok` confirms success.

---

### 4. Get Operations

**Pattern**: `{:ok, resource} | {:error, :not_found}`

**When to use**: Functions that fetch a single resource by ID or unique key.

**Examples**:
```elixir
def get_torrent(id) do
  case Repo.get(Torrent, id) do
    nil -> {:error, :not_found}
    torrent -> {:ok, torrent}
  end
end
# Returns: {:ok, %Torrent{}} | {:error, :not_found}

def lookup(parent_id, name) do
  result =
    DirectoryEntry
    |> where([e], e.parent_inode_id == ^parent_id and e.name == ^name)
    |> join(:inner, [e], i in Inode, on: e.inode_id == i.inode_id)
    |> select([_e, i], i)
    |> Repo.one()

  case result do
    nil -> {:error, :not_found}
    inode -> {:ok, inode}
  end
end
# Returns: {:ok, %Inode{}} | {:error, :not_found}
```

**Rationale**: Tuple pattern allows pipeline composition with `with` statements. Always use `:not_found` (never `:torrent_not_found`, `:file_not_found`, etc.).

---

### 5. List Operations

**Pattern**: `[resource]` (list, never nil)

**When to use**: Functions that fetch multiple resources.

**Examples**:
```elixir
def list_torrents do
  Repo.all(Torrent)
end
# Returns: [%Torrent{}] (empty list if none)

def list_children(inode_id) do
  DirectoryEntry
  |> where([e], e.parent_inode_id == ^inode_id)
  |> join(:inner, [e], i in Inode, on: e.inode_id == i.inode_id)
  |> select([e, i], {e, i})
  |> Repo.all()
end
# Returns: [{%DirectoryEntry{}, %Inode{}}]
```

**Rationale**: Empty list is semantically correct for "no results". Avoids nil checks and simplifies enumeration.

---

### 6. Boolean Check Operations

**Pattern**: `true | false`

**When to use**: Functions that check existence or conditions.

**Examples**:
```elixir
def torrent_rejected?(rd_id) do
  RejectedTorrent
  |> where([r], r.rd_id == ^rd_id)
  |> Repo.exists?()
end
# Returns: true | false

def has_hardlinks?(inode) do
  inode.nlink > 1
end
# Returns: true | false
```

**Rationale**: Boolean predicates (ending in `?`) should always return boolean values, never tuples.

---

### 7. Async/Side-Effect Operations

**Pattern**: `:ok`

**When to use**: Functions that enqueue work, send messages, or perform side effects without meaningful return value.

**Examples**:
```elixir
def enqueue(torrent_id) when is_integer(torrent_id) do
  SyncEngine.JobQueue.enqueue(:delete_torrent, %{torrent_id: torrent_id})
end
# Returns: :ok

def enqueue_batch(torrent_ids) when is_list(torrent_ids) do
  Enum.each(torrent_ids, &enqueue/1)
end
# Returns: :ok (Enum.each always returns :ok)
```

**Rationale**: Async operations complete immediately; actual result comes later via callbacks, monitoring, or polling.

---

## Error Handling

### Standard Error Atoms

Use **generic error atoms** that indicate the error class, not the specific resource type.

#### ✅ Correct
```elixir
{:error, :not_found}
{:error, :invalid}
{:error, :already_exists}
{:error, :unauthorized}
{:error, :directory_not_empty}
{:error, :cannot_delete_root}
```

#### ❌ Incorrect
```elixir
{:error, :torrent_not_found}     # Too specific
{:error, :user_not_found}        # Too specific
{:error, :invalid_torrent_data}  # Too specific
```

**Rationale**: The calling context already knows what resource is being queried. Generic atoms enable consistent error handling across modules.

### Error Context

When additional context is needed, use a map or structured error:

```elixir
# For complex errors, provide context
{:error, {:validation_failed, %{field: :email, reason: "invalid format"}}}

# Or use custom error structs
defmodule MyApp.Error do
  defstruct [:type, :message, :details]
end

{:error, %MyApp.Error{type: :validation, message: "Invalid data", details: %{...}}}
```

---

## Transaction Handling

### Use `Repo.transact/1` Consistently

**Prefer** `Repo.transact/1` over `Repo.transaction/1` for consistency.

#### ✅ Correct
```elixir
def create_with_files(attrs) do
  Repo.transact(fn ->
    with {:ok, torrent} <- create_torrent(attrs),
         {:ok, _files} <- create_files(torrent) do
      torrent
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end)
end
# Returns: {:ok, %Torrent{}} | {:error, reason}
```

#### ❌ Avoid
```elixir
# Mixing transaction styles
def create_with_files(attrs) do
  Repo.transaction(fn ->  # Should use transact/1
    # ...
  end)
end
```

**Note**: If `Repo.transact/1` doesn't exist in your repo, use `Repo.transaction/1` consistently.

---

### Unwrapping Transaction Results

#### Pattern 1: Transform to `:ok` (for delete operations)

```elixir
def mark_for_deletion(torrent_id) do
  case get_torrent(torrent_id) do
    {:ok, torrent} ->
      torrent
      |> Ecto.Changeset.change(%{deletion_status: "pending_deletion"})
      |> Repo.update()
      |> case do
        {:ok, _updated} -> :ok
        {:error, changeset} -> {:error, changeset}
      end

    {:error, :not_found} ->
      {:error, :not_found}
  end
end
```

#### Pattern 2: Keep the tuple (for create/update operations)

```elixir
def create_directory(parent_id, name) do
  Repo.transact(fn ->
    {:ok, inode} =
      %Inode{}
      |> Inode.changeset(%{mode: FileMode.directory_mode()})
      |> Repo.insert()

    {:ok, _entry} =
      %DirectoryEntry{}
      |> DirectoryEntry.changeset(%{parent_inode_id: parent_id, name: name, inode_id: inode.inode_id})
      |> Repo.insert()

    inode
  end)
end
# Returns: {:ok, %Inode{}} | {:error, reason}
```

#### ❌ Avoid: No-op case statements

```elixir
# DON'T DO THIS
|> case do
  {:ok, result} -> {:ok, result}  # Redundant
  {:error, reason} -> {:error, reason}
end

# Just return the result directly
```

---

## Type Specifications

Add `@spec` annotations to **all public API functions**.

### Syntax

```elixir
@spec function_name(arg1_type, arg2_type) :: return_type
```

### Examples

```elixir
@spec get_torrent(integer()) :: {:ok, Torrent.t()} | {:error, :not_found}
def get_torrent(id) do
  # ...
end

@spec create_directory(integer(), String.t(), keyword()) :: {:ok, Inode.t()} | {:error, term()}
def create_directory(parent_id, name, opts \\ []) do
  # ...
end

@spec list_torrents() :: [Torrent.t()]
def list_torrents do
  # ...
end

@spec torrent_rejected?(String.t()) :: boolean()
def torrent_rejected?(rd_id) do
  # ...
end

@spec enqueue(integer()) :: :ok
def enqueue(torrent_id) do
  # ...
end
```

### Type Aliases

Define custom types for clarity:

```elixir
defmodule VFS do
  @type inode_id :: integer()
  @type error_reason :: atom() | {:error, term()}
  
  @spec lookup(inode_id(), String.t()) :: {:ok, Inode.t()} | {:error, :not_found}
  def lookup(parent_id, name) do
    # ...
  end
end
```

---

## Naming Conventions

### Function Names

1. **Query functions**: `get_`, `list_`, `find_`
   ```elixir
   get_torrent(id)
   list_torrents()
   find_all_hardlinks(inode_id)
   ```

2. **Mutation functions**: `create_`, `update_`, `delete_`, `remove_`
   ```elixir
   create_torrent(attrs)
   update_torrent(torrent, attrs)
   delete_torrent(torrent)
   remove(parent_id, name)
   ```

3. **Boolean predicates**: End with `?`
   ```elixir
   torrent_rejected?(rd_id)
   is_virtual_inode?(inode)
   has_hardlinks?(inode)
   ```

4. **Side effects**: Use imperative verbs
   ```elixir
   enqueue(job)
   schedule_poll()
   mark_for_deletion(id)
   ```

### Module Organization

Group related functions:

```elixir
defmodule SyncEngine.Torrents do
  # Query functions
  def list_torrents, do: ...
  def get_torrent(id), do: ...
  def get_torrent_by_rd_id(rd_id), do: ...
  
  # Creation functions
  def create_torrent(attrs), do: ...
  def create_torrent_file(attrs), do: ...
  
  # Update functions
  def update_torrent(torrent, attrs), do: ...
  def mark_for_deletion(id), do: ...
  
  # Deletion functions
  def delete_torrent(torrent), do: ...
  def cleanup_after_deletion(id), do: ...
  
  # Boolean checks
  def torrent_rejected?(rd_id), do: ...
end
```

---

## Code Examples

### Example: Context Module (VFS)

```elixir
defmodule VFS do
  @moduledoc """
  Virtual filesystem context - public API for filesystem operations.
  """

  alias VFS.{Repo, Inode, DirectoryEntry}

  # Types
  @type inode_id :: integer()
  @type name :: String.t()

  ## Query Operations

  @spec get_root() :: {:ok, Inode.t()} | {:error, term()}
  def get_root do
    case Repo.get(Inode, 1) do
      nil -> create_root()
      root -> {:ok, root}
    end
  end

  @spec get_inode(inode_id()) :: {:ok, Inode.t()} | {:error, :not_found}
  def get_inode(inode_id) do
    case Repo.get(Inode, inode_id) do
      nil -> {:error, :not_found}
      inode -> {:ok, inode}
    end
  end

  @spec list_children(inode_id()) :: [{DirectoryEntry.t(), Inode.t()}]
  def list_children(inode_id) do
    DirectoryEntry
    |> where([e], e.parent_inode_id == ^inode_id)
    |> join(:inner, [e], i in Inode, on: e.inode_id == i.inode_id)
    |> select([e, i], {e, i})
    |> Repo.all()
  end

  ## Creation Operations

  @spec create_directory(inode_id(), name(), keyword()) :: {:ok, Inode.t()} | {:error, term()}
  def create_directory(parent_id, name, opts \\ []) do
    Repo.transact(fn ->
      {:ok, inode} =
        %Inode{}
        |> Inode.changeset(%{mode: FileMode.directory_mode()})
        |> Repo.insert()

      {:ok, _entry} =
        %DirectoryEntry{}
        |> DirectoryEntry.changeset(%{
          parent_inode_id: parent_id,
          name: name,
          inode_id: inode.inode_id
        })
        |> Repo.insert()

      inode
    end)
  end

  ## Deletion Operations

  @spec remove(inode_id(), name(), keyword()) :: :ok | {:error, atom()}
  def remove(parent_id, name, opts \\ []) do
    result =
      Repo.transact(fn ->
        # ... deletion logic
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Boolean Checks

  @spec is_virtual_inode?(Inode.t()) :: boolean()
  def is_virtual_inode?(inode) do
    not is_nil(inode.virtual_inode_type) and not is_nil(inode.virtual_inode_id)
  end
end
```

### Example: Service Module

```elixir
defmodule SyncEngine.Services.TorrentSync do
  @moduledoc """
  Synchronizes RealDebrid torrents with local VFS.
  """

  require Logger
  alias VFS.Repo

  @type sync_result :: %{
    added: non_neg_integer(),
    removed: non_neg_integer(),
    skipped: non_neg_integer(),
    errors: [term()]
  }

  @spec sync(RealDebrid.Client.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync(client, opts \\ []) do
    torrents_root_id = Keyword.fetch!(opts, :torrents_root_id)

    with {:ok, rd_torrents} <- fetch_rd_torrents(client),
         {:ok, db_data} <- fetch_db_torrents() do
      result = perform_sync(client, rd_torrents, db_data, torrents_root_id)
      {:ok, result}
    end
  end

  # Private functions follow same conventions
  defp fetch_rd_torrents(client) do
    case RealDebrid.Api.Torrents.get_all(client) do
      {:ok, torrents} -> {:ok, Enum.filter(torrents, &completed?/1)}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

---

## Summary Checklist

When writing new functions, ensure:

- [ ] Return type matches operation category (create/update/delete/get/list/check/async)
- [ ] Error atoms are generic (`:not_found`, not `:torrent_not_found`)
- [ ] Transaction results are properly unwrapped (avoid no-op case statements)
- [ ] `@spec` annotation is present for public functions
- [ ] Function name follows conventions (`get_`, `create_`, `is_`, etc.)
- [ ] Documentation explains **why**, not just **what**

---

## References

- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Ecto Best Practices](https://hexdocs.pm/ecto/Ecto.html)
- [Typespecs](https://hexdocs.pm/elixir/typespecs.html)

---

**Last Updated**: December 14, 2025  
**Maintained By**: Development Team
