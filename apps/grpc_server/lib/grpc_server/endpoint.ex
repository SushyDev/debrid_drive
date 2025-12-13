defmodule GrpcServer.Endpoint do
  @moduledoc """
  gRPC endpoint configuration for the FileSystemService.

  This module registers the FileSystemService.Server as the primary gRPC service handler.

  ## Usage

  The endpoint is configured in sync_engine via the `:grpc_endpoint` application config,
  allowing sync_engine to start the gRPC server without directly depending on grpc_server.
  This breaks the circular dependency while maintaining clean separation of concerns.

  ## Dependency Design

  To avoid circular dependencies in the umbrella project:
  - grpc_server provides the endpoint (this module)
  - sync_engine starts the gRPC server using the configured endpoint
  - grpc_server still depends on sync_engine for business logic
  - sync_engine doesn't depend on grpc_server at compile time

  The endpoint module is injected at runtime via application config.
  """

  use GRPC.Endpoint

  run(GrpcServer.FileSystemService.Server)
end
