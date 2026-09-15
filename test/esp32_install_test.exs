defmodule Mix.Tasks.Atomvm.Esp32.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.Install

  test "rejects using image and version together" do
    assert_raise Mix.Error, "--image and --version cannot be used together", fn ->
      Install.run(["--image", "atomvm.img", "--version", "v0.7.0-alpha.1"])
    end
  end

  test "rejects an image that is neither a file nor a published image name" do
    for arg <- ["./missing.img", "not-an-image.uf2", "atomvm-esp32s3-elixir.img"] do
      assert_raise Mix.Error, ~r/^--image must be an image file or the name/, fn ->
        Install.run(["--image", arg])
      end
    end
  end
end
