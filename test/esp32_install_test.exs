defmodule Mix.Tasks.Atomvm.Esp32.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.Install

  test "rejects using image and version together" do
    assert_raise Mix.Error, "--image and --version cannot be used together", fn ->
      Install.run(["--image", "atomvm.img", "--version", "v0.7.0-alpha.1"])
    end
  end

  test "rejects --list-images together with an image, a version, --update or --download-only" do
    message =
      "--list-images cannot be combined with --image, --version, --update or --download-only"

    for args <- [["--version", "v0.6.6"], ["--image", "x.img"], ["--update"], ["--download-only"]] do
      assert_raise Mix.Error, message, fn -> Install.run(["--list-images" | args]) end
    end
  end

  test "rejects --chip where the chip is not needed" do
    message = "--chip only applies to --list-images, and to --download-only without --image"

    for args <- [[], ["--download-only", "--image", "AtomVM-esp32s3-elixir-v0.6.6"]] do
      assert_raise Mix.Error, message, fn -> Install.run(["--chip", "esp32s3" | args]) end
    end
  end

  test "rejects --download-only together with --update" do
    assert_raise Mix.Error, "--download-only and --update cannot be used together", fn ->
      Install.run(["--download-only", "--update"])
    end
  end

  test "rejects --download-only with an image file" do
    assert_raise Mix.Error, "--download-only needs a published image, mix.exs is a file", fn ->
      Install.run(["--download-only", "--image", "mix.exs"])
    end
  end

  test "points at the other images when installing the latest release" do
    assert Install.latest_release_hint("v0.6.6") == """
           💡 Installing AtomVM v0.6.6, the latest stable release.
              Nightly builds and images with extra components and features (for example
              PSRAM support) are also available: mix atomvm.esp32.install --list-images
           """
  end

  test "does not claim to install when only downloading the latest release" do
    hint = Install.latest_release_hint("v0.6.6", "Fetching")
    assert hint =~ "Fetching AtomVM v0.6.6, the latest stable release."
    refute hint =~ "Installing"
  end

  test "says where a downloaded image is and how to install it" do
    path = "firmware_images/AtomVM-esp32s3-elixir-v0.6.6.img"
    hint = Install.downloaded_hint(path)
    assert hint =~ "#{path} is ready."
    assert hint =~ "mix atomvm.esp32.install --image #{path}\n"
    refute hint =~ ~r/[^\x00-\x7F]/
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
