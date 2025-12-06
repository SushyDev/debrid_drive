ExUnit.start()

# Setup test database with SQL Sandbox for proper test isolation
Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, :manual)
