defmodule GrpcServerTest do
  use ExUnit.Case, async: false
  doctest GrpcServer

  test "module exists" do
    assert Code.ensure_loaded?(GrpcServer)
  end
end
