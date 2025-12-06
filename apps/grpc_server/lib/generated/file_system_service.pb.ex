defmodule StreamMountApi.RootRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3
end

defmodule StreamMountApi.RootResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :root, 1, type: StreamMountApi.Node
end

defmodule StreamMountApi.ReadDirAllRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node_id, 1, type: :uint64, json_name: "nodeId"
end

defmodule StreamMountApi.ReadDirAllResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :nodes, 1, repeated: true, type: StreamMountApi.Node
end

defmodule StreamMountApi.LookupRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node_id, 1, type: :uint64, json_name: "nodeId"
  field :name, 2, type: :string
end

defmodule StreamMountApi.LookupResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node, 1, type: StreamMountApi.Node
end

defmodule StreamMountApi.CreateRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :parent_node_id, 1, type: :uint64, json_name: "parentNodeId"
  field :name, 2, type: :string
  field :mode, 3, type: :uint32
end

defmodule StreamMountApi.CreateResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3
end

defmodule StreamMountApi.MkdirRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :parent_node_id, 1, type: :uint64, json_name: "parentNodeId"
  field :name, 2, type: :string
end

defmodule StreamMountApi.MkdirResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node, 1, type: StreamMountApi.Node
end

defmodule StreamMountApi.RemoveRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :parent_node_id, 1, type: :uint64, json_name: "parentNodeId"
  field :name, 2, type: :string
end

defmodule StreamMountApi.RemoveResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3
end

defmodule StreamMountApi.RenameRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :old_parent_node_id, 1, type: :uint64, json_name: "oldParentNodeId"
  field :old_name, 2, type: :string, json_name: "oldName"
  field :new_parent_node_id, 3, type: :uint64, json_name: "newParentNodeId"
  field :new_name, 4, type: :string, json_name: "newName"
end

defmodule StreamMountApi.RenameResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node, 1, type: StreamMountApi.Node
end

defmodule StreamMountApi.LinkRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node_id, 1, type: :uint64, json_name: "nodeId"
  field :parent_node_id, 2, type: :uint64, json_name: "parentNodeId"
  field :name, 3, type: :string
end

defmodule StreamMountApi.LinkResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node, 1, type: StreamMountApi.Node
end

defmodule StreamMountApi.GetFileInfoRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node_id, 1, type: :uint64, json_name: "nodeId"
end

defmodule StreamMountApi.GetFileInfoResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :size, 1, type: :uint64
  field :mode, 2, type: :uint32
end

defmodule StreamMountApi.GetStreamUrlRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node_id, 1, type: :uint64, json_name: "nodeId"
end

defmodule StreamMountApi.GetStreamUrlResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :url, 1, type: :string
end

defmodule StreamMountApi.ReadFileRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node_id, 1, type: :uint64, json_name: "nodeId"
  field :offset, 2, type: :uint64
  field :size, 3, type: :uint64
end

defmodule StreamMountApi.ReadFileResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :data, 1, type: :bytes
end

defmodule StreamMountApi.WriteFileRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :node_id, 1, type: :uint64, json_name: "nodeId"
  field :offset, 2, type: :uint64
  field :data, 3, type: :bytes
end

defmodule StreamMountApi.WriteFileResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :bytes_written, 1, type: :uint64, json_name: "bytesWritten"
end

defmodule StreamMountApi.Node do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :uint64
  field :name, 2, type: :string
  field :mode, 3, type: :uint32
  field :streamable, 4, type: :bool
end

defmodule StreamMountApi.FileSystemService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "stream_mount_api.FileSystemService",
    protoc_gen_elixir_version: "0.15.0"

  rpc :Root, StreamMountApi.RootRequest, StreamMountApi.RootResponse

  rpc :ReadDirAll, StreamMountApi.ReadDirAllRequest, StreamMountApi.ReadDirAllResponse

  rpc :Lookup, StreamMountApi.LookupRequest, StreamMountApi.LookupResponse

  rpc :Create, StreamMountApi.CreateRequest, StreamMountApi.CreateResponse

  rpc :Mkdir, StreamMountApi.MkdirRequest, StreamMountApi.MkdirResponse

  rpc :Remove, StreamMountApi.RemoveRequest, StreamMountApi.RemoveResponse

  rpc :Rename, StreamMountApi.RenameRequest, StreamMountApi.RenameResponse

  rpc :Link, StreamMountApi.LinkRequest, StreamMountApi.LinkResponse

  rpc :ReadFile, StreamMountApi.ReadFileRequest, StreamMountApi.ReadFileResponse

  rpc :WriteFile, StreamMountApi.WriteFileRequest, StreamMountApi.WriteFileResponse

  rpc :GetFileInfo, StreamMountApi.GetFileInfoRequest, StreamMountApi.GetFileInfoResponse

  rpc :GetStreamUrl, StreamMountApi.GetStreamUrlRequest, StreamMountApi.GetStreamUrlResponse
end

defmodule StreamMountApi.FileSystemService.Stub do
  @moduledoc false

  use GRPC.Stub, service: StreamMountApi.FileSystemService.Service
end
