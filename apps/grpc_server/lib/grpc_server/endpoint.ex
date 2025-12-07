defmodule GrpcServer.Endpoint do
  use GRPC.Endpoint

  run(GrpcServer.FileSystemService.Server)
end
