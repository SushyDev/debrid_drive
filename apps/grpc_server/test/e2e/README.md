# gRPC Server End-to-End Tests

Comprehensive test suite for the gRPC filesystem server, including stress tests, concurrent operations, property-based tests, and edge cases.

## Test Structure

The E2E tests are organized into several test files:

### 1. `test/e2e/filesystem_correctness_test.exs`
Basic filesystem correctness tests covering:
- Root operations
- Directory CRUD operations
- File CRUD operations
- Remove operations
- Rename/Move operations
- Data integrity verification

### 2. `test/e2e/concurrent_stress_test.exs`
Stress and concurrency tests including:
- Concurrent reads from multiple clients
- Concurrent writes to different files
- Concurrent directory operations
- Mixed concurrent operations (read/write/create)
- High volume operations (100s of files)
- Deep directory nesting (50-100 levels)
- Large file operations (1MB-10MB)
- Rapid create/delete cycles

### 3. `test/e2e/property_based_test.exs`
Property-based tests using StreamData that verify:
- Write-then-read returns identical data
- File size matches content length
- Directory listings are consistent
- Rename operations preserve content
- Partial reads return correct substrings
- Last write wins on overwrites
- Empty operations behave correctly

### 4. `test/e2e/edge_case_test.exs`
Edge cases and boundary conditions:
- Empty files
- Large files (10MB+)
- Deep directory structures (100 levels)
- Wide directories (1000+ files)
- Special characters in filenames
- Binary data with null bytes
- Unicode and UTF-8 content
- Reading beyond file boundaries
- Sparse file writes (offset with padding)

## Running the Tests

### Prerequisites

1. **Start the gRPC server** - The tests assume a gRPC server is running on `localhost:50051`
2. **Install dependencies**:
   ```bash
   mix deps.get
   ```
3. **Set up the database**:
   ```bash
   cd ../vfs
   mix ecto.create
   mix ecto.migrate
   ```

### Running All Tests

```bash
# Run all tests
mix test

# Run only E2E tests
mix test test/e2e/

# Run with detailed output
mix test --trace
```

### Running Specific Test Files

```bash
# Filesystem correctness tests
mix test test/e2e/filesystem_correctness_test.exs

# Concurrent/stress tests
mix test test/e2e/concurrent_stress_test.exs

# Property-based tests
mix test test/e2e/property_based_test.exs

# Edge case tests
mix test test/e2e/edge_case_test.exs
```

### Running Specific Tests

```bash
# Run a specific test by line number
mix test test/e2e/filesystem_correctness_test.exs:25

# Run tests matching a pattern
mix test --only edge_case
```

## Test Configuration

### Database Sandbox

The tests use Ecto's SQL Sandbox for test isolation. Each test gets a clean database state:

```elixir
# In test_helper.exs
Ecto.Adapters.SQL.Sandbox.mode(StreamMount.VFS.Repo, :manual)

# In each test setup
:ok = Ecto.Adapters.SQL.Sandbox.checkout(StreamMount.VFS.Repo)
```

### Timeouts

Some stress tests have extended timeouts due to large operations:

```elixir
@tag timeout: 60_000  # 60 seconds
test "large file operations" do
  # ...
end
```

## Test Helper Module

The `GrpcServer.Test.GrpcClientHelper` module provides convenience functions:

```elixir
# Connect to server
channel = GrpcClientHelper.connect()

# Get root
{:ok, root_resp} = GrpcClientHelper.get_root(channel)

# Create directory
{:ok, dir_resp} = GrpcClientHelper.mkdir(channel, parent_id, "dirname")

# Create file
{:ok, _} = GrpcClientHelper.create_file(channel, parent_id, "file.txt")

# Write data
{:ok, _} = GrpcClientHelper.write_file(channel, file_id, "content")

# Read data
{:ok, read_resp} = GrpcClientHelper.read_file(channel, file_id)

# Cleanup
GrpcClientHelper.disconnect(channel)
```

## Key Test Scenarios

### Filesystem Correctness
- ✓ Basic CRUD operations work correctly
- ✓ Data written can be read back identically
- ✓ File sizes are tracked accurately
- ✓ Directory listings are complete
- ✓ Rename preserves file content
- ✓ Remove makes files unfindable

### Concurrency & Stress
- ✓ Multiple clients can read simultaneously
- ✓ Concurrent writes don't interfere
- ✓ 100+ files can be created rapidly
- ✓ 50-100 level deep directories work
- ✓ 1MB-10MB files can be handled
- ✓ 1000+ files in a directory work

### Edge Cases
- ✓ Empty files (size 0)
- ✓ Large files (10MB+)
- ✓ Binary data with null bytes
- ✓ Unicode filenames and content
- ✓ Special characters in names
- ✓ Reading beyond file boundaries
- ✓ Sparse writes with padding

## Performance Benchmarks

The stress tests provide insight into server performance:

- **Create 100 files**: Should complete in < 10 seconds
- **Read 20 files concurrently**: Should complete in < 5 seconds
- **Write 1MB file**: Should complete in < 2 seconds
- **List 1000 files**: Should complete in < 3 seconds

## Troubleshooting

### Tests Fail to Connect

If tests fail with connection errors:

1. Ensure the gRPC server is running:
   ```bash
   # Start the server (adjust command as needed)
   iex -S mix
   ```

2. Verify the server is listening on port 50051:
   ```bash
   lsof -i :50051
   ```

3. Check the server configuration in the application

### Database Errors

If you see database errors:

1. Ensure migrations are run:
   ```bash
   cd ../vfs
   mix ecto.migrate
   ```

2. Reset the test database:
   ```bash
   MIX_ENV=test mix ecto.reset
   ```

### Timeout Errors

If stress tests timeout:

1. Increase the timeout in the test:
   ```elixir
   @tag timeout: 120_000  # 2 minutes
   ```

2. Check server performance and logs

## Future Enhancements

Potential additions to the test suite:

- [ ] Performance benchmarking suite
- [ ] Memory leak detection tests
- [ ] Network failure simulation
- [ ] Database failure recovery tests
- [ ] Streaming large file tests
- [ ] Permission/access control tests
- [ ] Symlink operation tests

## Contributing

When adding new tests:

1. Follow the existing test structure
2. Use descriptive test names
3. Add comments for complex test logic
4. Update this README with new test categories
5. Ensure tests are isolated and repeatable
