defmodule ExAtomVM.Esp32FirmwareImagesTest do
  use ExUnit.Case, async: true

  alias ExAtomVM.Esp32FirmwareImages, as: Images

  @releases "https://api.github.com/repos/atomvm/atomvm/releases"

  describe "release_api_url/1" do
    test "uses the latest release endpoint when no version is specified" do
      assert Images.release_api_url(nil) == @releases <> "/latest"
    end

    test "uses the tagged release endpoint for a specific version" do
      assert Images.release_api_url("v0.7.0-alpha.1") == @releases <> "/tags/v0.7.0-alpha.1"
    end

    test "encodes the version as a URL path segment" do
      assert Images.release_api_url("release/0.7.0") == @releases <> "/tags/release%2F0.7.0"
    end
  end

  describe "parse_name/1" do
    test "parses a release image for a chip variant with a prerelease version" do
      assert {:ok, image} = Images.parse_name("AtomVM-esp32p4_pre_c6-elixir-v0.7.0-alpha.1.img")

      assert image == %{
               name: "AtomVM-esp32p4_pre_c6-elixir-v0.7.0-alpha.1",
               file: "AtomVM-esp32p4_pre_c6-elixir-v0.7.0-alpha.1.img",
               kind: :img,
               chip: "esp32p4_pre_c6",
               base_chip: "esp32p4",
               elixir?: true,
               features: [],
               version: "v0.7.0-alpha.1",
               channel: :prerelease,
               stamp: nil
             }
    end

    test "parses an Erlang-only stable release image" do
      assert {:ok, %{chip: "esp32", elixir?: false, version: "v0.6.6", channel: :stable}} =
               Images.parse_name("AtomVM-esp32-v0.6.6.img")
    end

    test "parses an image built by mix atomvm.esp32.build" do
      assert {:ok, %{chip: "esp32s3", elixir?: true, version: nil, channel: :local}} =
               Images.parse_name("atomvm-esp32s3-elixir.img")
    end

    test "parses a firmware factory bundle" do
      assert {:ok, image} =
               Images.parse_name("AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7.zip")

      assert %{
               kind: :zip,
               chip: "esp32s3",
               elixir?: false,
               features: ["atomgl", "ipv6", "libsodium", "psram"],
               version: "nightly-0.7",
               channel: :nightly,
               stamp: nil
             } = image
    end

    test "parses a cached bundle carrying its build stamp" do
      assert {:ok, image} =
               Images.parse_name(
                 "AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7+20260915.02e1603.zip"
               )

      assert image.name == "AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7"
      assert image.version == "nightly-0.7"
      assert image.stamp == "nightly-0.7+20260915.02e1603"
    end

    test "accepts a path and a bare name" do
      assert {:ok, %{file: "AtomVM-esp32s3-elixir-v0.6.6.img", kind: :img}} =
               Images.parse_name("firmware_images/AtomVM-esp32s3-elixir-v0.6.6.img")

      assert {:ok, %{name: "AtomVM-esp32s3-elixir-v0.6.6", file: nil, kind: nil}} =
               Images.parse_name("AtomVM-esp32s3-elixir-v0.6.6")
    end

    test "rejects names that are not ESP32 images" do
      for name <- [
            "AtomVM-esp32-elixir-v0.6.6.img.sha256",
            "AtomVM-linux-x86_64-v0.6.6",
            "atomvmlib-v0.6.6.avm",
            "AtomVM-pico-v0.6.6.uf2",
            "esp32s3-kiosk.img",
            "AtomVM-ESP32S3-elixir-v0.6.6.img"
          ] do
        assert {:error, {:unrecognized_name, _}} = Images.parse_name(name), name
      end
    end
  end

  describe "chip_token/1" do
    test "turns the chip family reported by esptool into the name token" do
      assert Images.chip_token("ESP32") == "esp32"
      assert Images.chip_token("ESP32-S3") == "esp32s3"
      assert Images.chip_token("ESP32-C61") == "esp32c61"
      assert Images.chip_token("ESP32-P4") == "esp32p4"
      assert Images.chip_token("ESP32-S2 (QFN56)") == "esp32s2"
    end
  end

  describe "release_images/1" do
    test "keeps the ESP32 images with their download details" do
      images = Images.release_images(release("v0.6.6"))

      assert Enum.map(images, & &1.name) == [
               "AtomVM-esp32-elixir-v0.6.6",
               "AtomVM-esp32-v0.6.6",
               "AtomVM-esp32s3-elixir-v0.6.6",
               "AtomVM-esp32s3-v0.6.6"
             ]

      assert %{
               source: :atomvm,
               tag: "v0.6.6",
               url:
                 "https://github.com/atomvm/AtomVM/releases/download/v0.6.6/AtomVM-esp32-elixir-v0.6.6.img",
               size: 2_197_764,
               published_at: "2025-06-23",
               sha256: "33a9c076a0c8cb67118f31342262430c932e7c6fe152924bd60cd249022a92b8",
               sha256_url:
                 "https://github.com/atomvm/AtomVM/releases/download/v0.6.6/AtomVM-esp32-elixir-v0.6.6.img.sha256",
               channel: :stable
             } = hd(images)
    end

    test "marks the images of a prerelease" do
      [image | _] = Images.release_images(release("v0.7.0-alpha.1", prerelease: true))
      assert image.channel == :prerelease
    end
  end

  describe "digest_from_asset/1" do
    test "reads the sha256 digest GitHub reports" do
      hex = String.duplicate("ab", 32)
      assert Images.digest_from_asset(%{"digest" => "sha256:" <> String.upcase(hex)}) == hex
      assert Images.digest_from_asset(%{"digest" => nil}) == nil
      assert Images.digest_from_asset(%{}) == nil
    end
  end

  describe "cached_file_name/1" do
    test "keeps the file name of a release image" do
      {:ok, image} = Images.parse_name("AtomVM-esp32s3-elixir-v0.6.6.img")
      assert Images.cached_file_name(image) == "AtomVM-esp32s3-elixir-v0.6.6.img"
    end

    test "adds the build stamp on a rolling tag" do
      {:ok, bundle} = Images.parse_name("AtomVM-esp32s3-psram-nightly-0.7.zip")

      assert Images.cached_file_name(%{bundle | stamp: "nightly-0.7+20260915.02e1603"}) ==
               "AtomVM-esp32s3-psram-nightly-0.7+20260915.02e1603.zip"

      [image] =
        Images.release_images(rolling_release("nightly-0.7", "AtomVM-esp32s3-nightly-0.7.img"))

      assert image.stamp == "nightly-0.7+20250623"
      assert Images.cached_file_name(image) == "AtomVM-esp32s3-nightly-0.7+20250623.img"
    end
  end

  describe "cached_images/2" do
    test "finds the copies of an image, newest build first" do
      files = [
        "AtomVM-esp32s3-elixir-v0.6.6.img",
        "AtomVM-esp32s3-elixir-v0.6.6.img.part",
        "AtomVM-esp32s3-psram-nightly-0.7+20260914.7ab12cd.zip",
        "AtomVM-esp32s3-psram-nightly-0.7+20260915.02e1603.img",
        "AtomVM-esp32s3-psram-nightly-0.7+20260915.02e1603.zip",
        "AtomVM-esp32s3-v0.6.6.img"
      ]

      assert [%{file: "AtomVM-esp32s3-elixir-v0.6.6.img", source: :cache}] =
               Images.cached_images(files, "AtomVM-esp32s3-elixir-v0.6.6")

      assert Enum.map(Images.cached_images(files, "AtomVM-esp32s3-psram-nightly-0.7"), & &1.file) ==
               [
                 "AtomVM-esp32s3-psram-nightly-0.7+20260915.02e1603.zip",
                 "AtomVM-esp32s3-psram-nightly-0.7+20260915.02e1603.img",
                 "AtomVM-esp32s3-psram-nightly-0.7+20260914.7ab12cd.zip"
               ]

      assert Images.cached_images(files, "AtomVM-esp32s3-psram-nightly-0.8") == []
    end
  end

  describe "parse_sha256_lines/1" do
    test "reads sha256sum output" do
      hex = "7a3bc8a21ec2dedf82f5bd89514f9e55eec6fc3871e620f2bd17b6e4996746a8"

      assert Images.parse_sha256_lines("#{hex}  AtomVM-esp32s3-elixir-v0.6.6.img\n") ==
               [{hex, "AtomVM-esp32s3-elixir-v0.6.6.img"}]

      assert [{_, "x.img"}, {_, "sdkconfig"}] =
               Images.parse_sha256_lines("#{hex}  x.img\n#{String.upcase(hex)}  sdkconfig\n")

      assert Images.parse_sha256_lines("garbage\n\n") == []
    end
  end

  describe "verify_sha256/2" do
    test "compares the digest, whatever its case" do
      hex = :crypto.hash(:sha256, "data") |> Base.encode16(case: :lower)
      other = :crypto.hash(:sha256, "other") |> Base.encode16(case: :lower)

      assert Images.verify_sha256("data", String.upcase(hex)) == :ok
      assert Images.verify_sha256("other", hex) == {:error, {:digest_mismatch, hex, other}}
    end
  end

  describe "gitignore_hint/1" do
    test "suggests the entry unless the cache directory is ignored" do
      assert Images.gitignore_hint(nil) =~ "echo '/firmware_images/' >> .gitignore"
      assert Images.gitignore_hint("/_build/\n/deps/\n") =~ "firmware_images/"
      assert Images.gitignore_hint("/_build/\n/firmware_images/\n") == nil
      assert Images.gitignore_hint("firmware_images\n") == nil
    end
  end

  describe "select_release_image/3" do
    setup do
      %{images: Images.release_images(release("v0.7.0-alpha.1", prerelease: true))}
    end

    test "matches the chip token exactly", %{images: images} do
      assert {:ok, %{name: "AtomVM-esp32-elixir-v0.7.0-alpha.1"}} =
               Images.select_release_image(images, "v0.7.0-alpha.1", "esp32")

      assert {:ok, %{name: "AtomVM-esp32c6-elixir-v0.7.0-alpha.1"}} =
               Images.select_release_image(images, "v0.7.0-alpha.1", "esp32c6")

      assert {:ok, %{name: "AtomVM-esp32c61-elixir-v0.7.0-alpha.1"}} =
               Images.select_release_image(images, "v0.7.0-alpha.1", "esp32c61")

      assert {:ok, %{name: "AtomVM-esp32p4-elixir-v0.7.0-alpha.1"}} =
               Images.select_release_image(images, "v0.7.0-alpha.1", "esp32p4")
    end

    test "requires an Elixir image and names the Erlang-only one" do
      images = Images.release_images(release("v0.6.4", elixir: false))

      assert {:error, {:no_elixir_image, "v0.6.4", "esp32", "AtomVM-esp32-v0.6.4"}} =
               Images.select_release_image(images, "v0.6.4", "esp32")
    end

    test "lists the chips of the release when none matches", %{images: images} do
      assert {:error, {:no_image_for_chip, "v0.7.0-alpha.1", "esp32c5", chips}} =
               Images.select_release_image(images, "v0.7.0-alpha.1", "esp32c5")

      assert chips == ["esp32", "esp32c6", "esp32c61", "esp32p4", "esp32p4_pre", "esp32s3"]
    end
  end

  describe "format_error/1" do
    test "describes every reason in one line" do
      for reason <- [
            {:no_image_for_chip, "v0.6.6", "esp32c5", ["esp32", "esp32s3"]},
            {:no_elixir_image, "v0.6.4", "esp32", "AtomVM-esp32-v0.6.4"},
            {:unrecognized_name, "x.uf2"},
            {:release_not_found, :atomvm, "v0.9.9"},
            {:http, "https://api.github.com/x", {:status, 403}},
            {:http, "https://api.github.com/x", {:status, 500}},
            {:http, "https://api.github.com/x", {:transport, "nxdomain"}},
            {:size_mismatch, "x.img", 10, 9},
            {:digest_mismatch, "x.img", "aa", "bb"},
            :something_else
          ] do
        message = Images.format_error(reason)
        assert is_binary(message) and message != ""
        refute message =~ "\n"
      end
    end
  end

  defp release(tag, opts \\ []) do
    chips =
      if tag == "v0.6.6",
        do: ["esp32", "esp32s3"],
        else: ["esp32", "esp32c6", "esp32c61", "esp32p4", "esp32p4_pre", "esp32s3"]

    flavors = if Keyword.get(opts, :elixir, true), do: ["-elixir", ""], else: [""]

    images =
      for chip <- chips, flavor <- flavors do
        name = "AtomVM-#{chip}#{flavor}-#{tag}.img"
        [asset(tag, name, 2_197_764), asset(tag, name <> ".sha256", 97)]
      end

    others = [
      asset(tag, "AtomVM-linux-x86_64-#{tag}", 4_508_560),
      asset(tag, "AtomVM-pico-#{tag}.uf2", 1_167_360),
      asset(tag, "atomvmlib-#{tag}.avm", 285_016)
    ]

    %{
      "tag_name" => tag,
      "prerelease" => Keyword.get(opts, :prerelease, false),
      "draft" => false,
      "published_at" => "2025-06-23T23:04:23Z",
      "body" => "",
      "assets" => List.flatten(images) ++ others
    }
  end

  defp rolling_release(tag, name) do
    %{
      "tag_name" => tag,
      "prerelease" => false,
      "draft" => false,
      "published_at" => "2026-09-15T22:35:19Z",
      "body" => "",
      "assets" => [asset(tag, name, 2_216_048)]
    }
  end

  defp asset(tag, name, size) do
    %{
      "name" => name,
      "size" => size,
      "browser_download_url" =>
        "https://github.com/atomvm/AtomVM/releases/download/#{tag}/#{name}",
      "digest" => "sha256:33a9c076a0c8cb67118f31342262430c932e7c6fe152924bd60cd249022a92b8",
      "updated_at" => "2025-06-23T23:00:00Z",
      "content_type" => "application/octet-stream"
    }
  end
end
