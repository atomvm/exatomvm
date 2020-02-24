defmodule ExAtomVMTest do
  use ExUnit.Case
  doctest ExAtomVM

  test "greets the world" do
    assert ExAtomVM.hello() == :world
  end
end
