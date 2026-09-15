defmodule Mix.Tasks.Atomvm.Esp32.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.Install

  test "rejects using image and version together" do
    assert_raise Mix.Error, "--image and --version cannot be used together", fn ->
      Install.run(["--image", "atomvm.img", "--version", "v0.7.0-alpha.1"])
    end
  end
end
