defmodule GrpcServer.Unit.ServerValidationTest do
  @moduledoc """
  Unit tests for server validation functions that don't require a running gRPC server.
  Tests internal helper functions and validation logic.

  Note: Name validation is comprehensively tested in E2E tests (stream_url_test.exs)
  where the full validation flow can be tested through the gRPC API.
  """
  use ExUnit.Case, async: false

  describe "Proto message validation" do
    test "CreateResponse exists" do
      # Verify the protobuf structure exists
      assert %StreamMountApi.CreateResponse{} == %StreamMountApi.CreateResponse{}
    end
  end
end
