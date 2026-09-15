defmodule Mix.Tasks.Atomvm.Esp32.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.Install

  test "uses the latest release endpoint when no version is specified" do
    assert Install.release_api_url(nil) ==
             "https://api.github.com/repos/atomvm/atomvm/releases/latest"
  end

  test "uses the tagged release endpoint for a specific version" do
    assert Install.release_api_url("v0.7.0-alpha.1") ==
             "https://api.github.com/repos/atomvm/atomvm/releases/tags/v0.7.0-alpha.1"
  end

  test "encodes the version as a URL path segment" do
    assert Install.release_api_url("release/0.7.0") ==
             "https://api.github.com/repos/atomvm/atomvm/releases/tags/release%2F0.7.0"
  end

  test "rejects using image and version together" do
    assert_raise Mix.Error, "--image and --version cannot be used together", fn ->
      Install.run(["--image", "atomvm.img", "--version", "v0.7.0-alpha.1"])
    end
  end
end
