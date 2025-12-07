defmodule SyncEngine.Endpoint do
  @moduledoc """
  gRPC endpoint configuration.
  """

  use GRPC.Endpoint

  run(GrpcServer.FileSystemService.Server)
end
