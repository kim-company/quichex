defmodule QuichexTest do
  use ExUnit.Case
  doctest Quichex

  test "returns version" do
    assert Quichex.version() == "0.1.0"
  end

  test "NIF add function works" do
    assert Quichex.Native.add(2, 3) == 5
  end
end
