defmodule SyncEngineTest do
  use ExUnit.Case, async: false
  doctest SyncEngine

  test "greets the world" do
    assert SyncEngine.hello() == :world
  end
end
