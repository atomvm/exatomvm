defmodule Mix.Tasks.Atomvm.Esp32.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.Install

  test "rejects using image and version together" do
    assert_raise Mix.Error, "--image and --version cannot be used together", fn ->
      Install.run(["--image", "atomvm.img", "--version", "v0.7.0-alpha.1"])
    end
  end

  test "rejects --list-images together with an image, a version or --update" do
    message = "--list-images cannot be combined with --image, --version or --update"

    for args <- [["--version", "v0.6.6"], ["--image", "x.img"], ["--update"]] do
      assert_raise Mix.Error, message, fn -> Install.run(["--list-images" | args]) end
    end
  end

  test "rejects --chip without --list-images" do
    assert_raise Mix.Error, "--chip only applies to --list-images", fn ->
      Install.run(["--chip", "esp32s3"])
    end
  end

  test "rejects a repository that is not OWNER/REPO" do
    assert_raise Mix.Error, ~r/^--repo must be a GitHub repository/, fn ->
      Install.run(["--repo", "https://gitlab.com/acme/builds", "--list-images"])
    end
  end

  test "rejects stray and unknown arguments" do
    assert_raise Mix.Error, ~r/^Usage: mix atomvm.esp32.install/, fn -> Install.run(["extra"]) end

    assert_raise Mix.Error, ~r/^Usage: mix atomvm.esp32.install/, fn ->
      Install.run(["--bogus"])
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
