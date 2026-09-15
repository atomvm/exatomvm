defmodule ExAtomVM.Esp32FirmwareImagesTest do
  use ExUnit.Case, async: true

  alias ExAtomVM.Esp32FirmwareImages, as: Images

  @releases "https://api.github.com/repos/atomvm/atomvm/releases"

  @stem "AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7"
  @stamp "nightly-0.7+20260915.02e1603"

  @factory_body """
  Rolling nightly build of AtomVM `release-0.7` for ESP32-family chips, 2026-09-15.

  - AtomVM: `release-0.7` @ [`02e1603`](https://github.com/atomvm/AtomVM/commit/02e1603)
  - ESP-IDF v5.5.4 (container `espressif/idf:v5.5.4`)
  - Build stamp: `nightly-0.7+20260915.02e1603`

  | Image | Optimization | Size | SHA-256 | ELF SHA-256 | Status |
  |---|---|---|---|---|---|
  | `AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7.zip` | -O2 | 11288674 | `688f3c59` | `4539ff158` | fresh |
  """

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

  describe "stamp_from_body/1" do
    test "reads the build stamp of the factory release notes" do
      assert Images.stamp_from_body(@factory_body) == @stamp
      assert Images.stamp_from_body("no stamp here") == nil
      assert Images.stamp_from_body(nil) == nil
    end
  end

  describe "release_images/2 on the factory" do
    test "gives a bundle the build stamp of the release notes" do
      assert [image] = Images.release_images(factory_release(), :factory)

      assert %{
               source: :factory,
               kind: :zip,
               channel: :nightly,
               tag: "nightly-0.7",
               stamp: @stamp,
               published_at: "2026-09-15",
               size: 11_288_674
             } = image
    end
  end

  describe "parse_flash_txt/1" do
    test "reads the header and the parts" do
      assert {:ok, flash} = Images.parse_flash_txt(flash_txt("esp32s3"))

      assert flash == %{
               image: "#{@stem}.img",
               chip: "esp32s3",
               build: @stamp,
               idf: "5.5.4",
               flash_offset: 0x0,
               app_offset: 0x250000,
               parts: [
                 %{name: "bootloader.bin", offset: 0x0},
                 %{name: "partition-table.bin", offset: 0x40},
                 %{name: "atomvm-esp32.bin", offset: 0x80},
                 %{name: "esp32boot.avm", offset: 0x100}
               ]
             }
    end

    test "accepts the first bundle format, which listed no parts" do
      text = """
      AtomVM firmware image: x.img
      Chip: esp32
      Flash offset: 0x1000
      Application partition (main.avm): 0x250000

      Flash:
        esptool.py --chip esp32 write_flash \\
          0x1000 x.img
      """

      assert {:ok, %{chip: "esp32", flash_offset: 0x1000, build: nil, parts: []}} =
               Images.parse_flash_txt(text)
    end

    test "requires the chip and the flash offset" do
      assert Images.parse_flash_txt("Flash offset: 0x0\n") == {:error, {:bad_flash_txt, :chip}}
      assert Images.parse_flash_txt("Chip: esp32\n") == {:error, {:bad_flash_txt, :flash_offset}}
    end
  end

  describe "bundle_stamp/1" do
    test "reads CONFIG_APP_PROJECT_VER" do
      assert Images.bundle_stamp(sdkconfig()) == @stamp
      assert Images.bundle_stamp("CONFIG_IDF_TARGET=\"esp32s3\"\n") == nil
      assert Images.bundle_stamp(nil) == nil
    end
  end

  describe "verify_bundle/3" do
    test "accepts a factory bundle and returns its image, parts and stamp" do
      assert {:ok, bundle} = Images.verify_bundle(bundle(), "b.zip", @stamp)
      assert bundle.stem == @stem
      assert bundle.stamp == @stamp
      assert bundle.flash.chip == "esp32s3"
      assert bundle.image == image_bytes()
      assert bundle.partitions_csv == partitions_csv()

      assert bundle.parts ==
               Map.new(parts(), fn {name, _offset, data} -> {name, data} end)
    end

    test "accepts the first bundle format, without parts and SHA256SUMS" do
      flash_txt =
        flash_txt("esp32s3") |> String.split("Update an existing") |> hd() |> String.trim()

      members = Enum.take(members(flash_txt: flash_txt), 5)

      assert {:ok, %{parts: parts, stamp: @stamp}} =
               Images.verify_bundle(zip(members), "b.zip", nil)

      assert parts == %{}
    end

    test "rejects what is not a bundle" do
      assert {:error, {:bad_bundle, "b.zip", :not_a_zip}} =
               Images.verify_bundle("garbage", "b.zip", nil)

      assert {:error, {:bad_bundle, "b.zip", :no_image}} =
               Images.verify_bundle(zip([{"FLASH.txt", "x"}]), "b.zip", nil)

      assert {:error, {:bad_bundle, "b.zip", {:missing_members, ["FLASH.txt"]}}} =
               Images.verify_bundle(zip([{"x.img", "x"}]), "b.zip", nil)

      assert {:error, {:bad_bundle, "b.zip", {:missing_members, ["atomvm-esp32.bin"]}}} =
               Images.verify_bundle(
                 zip(List.keydelete(members(), "atomvm-esp32.bin", 0)),
                 "b.zip",
                 nil
               )
    end

    test "rejects a checksum mismatch" do
      sidecar = "#{String.duplicate("0", 64)}  #{@stem}.img\n"

      members =
        List.keyreplace(members(), "#{@stem}.img.sha256", 0, {"#{@stem}.img.sha256", sidecar})

      assert {:error, {:bad_bundle, "b.zip", {:sha256_mismatch, "#{@stem}.img"}}} =
               Images.verify_bundle(zip(members), "b.zip", nil)

      members =
        List.keyreplace(members(), "sdkconfig", 0, {"sdkconfig", sdkconfig() <> "# edited\n"})

      assert {:error, {:bad_bundle, "b.zip", {:sha256_mismatch, "sdkconfig"}}} =
               Images.verify_bundle(zip(members), "b.zip", nil)
    end

    test "rejects a part that is not the image's bytes at its offset" do
      parts = List.keyreplace(parts(), "atomvm-esp32.bin", 0, {"atomvm-esp32.bin", 0x80, "other"})

      assert {:error, {:bad_bundle, "b.zip", {:part_mismatch, "atomvm-esp32.bin", 0x80}}} =
               Images.verify_bundle(zip(members(parts: parts)), "b.zip", nil)
    end

    test "rejects a build stamp other than the expected one" do
      assert {:error, {:stamp_mismatch, "b.zip", "nightly-0.7+20260916.abcdef0", @stamp}} =
               Images.verify_bundle(bundle(), "b.zip", "nightly-0.7+20260916.abcdef0")
    end

    test "rejects a bundle built for another chip than its name says" do
      assert {:error, {:bad_bundle, "b.zip", {:chip, "esp32", "esp32s3"}}} =
               Images.verify_bundle(zip(members(chip: "esp32")), "b.zip", nil)
    end
  end

  describe "compatible?/2 and image_chip/1" do
    test "compares the base chip of the image with the connected one" do
      {:ok, image} = Images.parse_name("AtomVM-esp32p4_pre_c6-elixir-v0.7.0-alpha.1.img")
      assert Images.compatible?(image, "esp32p4") == true
      assert Images.compatible?(image, "esp32s3") == false
      assert Images.image_chip(image) == "esp32p4"

      local = Images.local_image("/tmp/kiosk.img")
      assert Images.compatible?(local, "esp32s3") == :unknown
      assert Images.image_chip(local) == nil

      bundle = Map.put(local, :flash, %{chip: "esp32s3", flash_offset: 0})
      assert Images.compatible?(bundle, "esp32s3") == true
    end
  end

  describe "flash_offset_for/2" do
    test "takes the bundle's offset, the chip's, and needs them to agree" do
      {:ok, image} = Images.parse_name("AtomVM-esp32-elixir-v0.6.6.img")
      assert Images.flash_offset_for(image, "esp32") == {:ok, 0x1000}
      assert Images.flash_offset_for(image, "esp32c5") == {:ok, 0x2000}
      assert Images.flash_offset_for(image, "esp32s3") == {:ok, 0x0}

      assert Images.flash_offset_for(image, "esp32x9") ==
               {:error, {:unknown_flash_offset, "esp32x9"}}

      bundle = Map.put(image, :flash, %{chip: "esp32", flash_offset: 0x1000})
      assert Images.flash_offset_for(bundle, "esp32") == {:ok, 0x1000}
      assert Images.flash_offset_for(bundle, "esp32x9") == {:ok, 0x1000}

      assert Images.flash_offset_for(bundle, "esp32s3") ==
               {:error, {:flash_offset_conflict, "AtomVM-esp32-elixir-v0.6.6.img", 0x1000, 0x0}}
    end
  end

  describe "classify_image_arg/1" do
    test "tells a file from a published image name" do
      assert Images.classify_image_arg("mix.exs") == {:path, "mix.exs"}

      assert {:name, %{name: "AtomVM-esp32s3-elixir-v0.6.6", version: "v0.6.6"}} =
               Images.classify_image_arg("AtomVM-esp32s3-elixir-v0.6.6")

      assert {:name, %{name: @stem, channel: :nightly}} =
               Images.classify_image_arg(@stem <> ".zip")

      assert Images.classify_image_arg("atomvm-esp32s3-elixir.img") == :error
      assert Images.classify_image_arg("./missing.img") == :error
    end
  end

  describe "local_image/1" do
    test "parses the name when it follows the convention" do
      path = "_build/atomvm_images/atomvm-esp32s3-elixir.img"

      assert %{chip: "esp32s3", elixir?: true, channel: :local, source: :local, path: ^path} =
               Images.local_image(path)

      assert %{name: "kiosk", file: "kiosk.img", chip: nil, elixir?: nil, channel: :local} =
               Images.local_image("/tmp/kiosk.img")
    end
  end

  describe "describe/2 and warnings/2" do
    test "describe a nightly bundle and warn about its missing Elixir support" do
      [image] = Images.release_images(factory_release(), :factory)

      assert Images.describe(image, 0) == [
               "#{@stem} (nightly build nightly-0.7, Erlang only)",
               "  build:    #{@stamp}",
               "  features: atomgl, ipv6, libsodium, psram",
               "  offset:   0x0"
             ]

      assert [warning] = Images.warnings(image, "esp32s3")
      assert warning =~ "no Elixir support"
    end

    test "describe a release image with nothing to warn about" do
      {:ok, image} = Images.parse_name("AtomVM-esp32s3-elixir-v0.6.6.img")

      assert Images.describe(image, 0x1000) == [
               "AtomVM-esp32s3-elixir-v0.6.6 (stable release v0.6.6, Elixir)",
               "  offset:   0x1000"
             ]

      assert Images.warnings(image, "esp32s3") == []
    end

    test "warn when the chip of a local image is not known" do
      image = Images.local_image("/tmp/kiosk.img")

      assert Images.describe(image, 0) == [
               "kiosk (local image, unknown flavor)",
               "  offset:   0x0"
             ]

      assert [warning] = Images.warnings(image, "esp32s3")
      assert warning =~ "not known"
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
            {:release_not_found, :factory, "nightly-0.8"},
            {:unknown_image, "AtomVM-esp32-v9.9.9", :atomvm},
            {:not_cached, "AtomVM-esp32-v9.9.9"},
            {:bad_bundle, "b.zip", :not_a_zip},
            {:bad_bundle, "b.zip", :no_image},
            {:bad_bundle, "b.zip", :unreadable},
            {:bad_bundle, "b.zip", {:missing_members, ["FLASH.txt", "sdkconfig"]}},
            {:bad_bundle, "b.zip", {:bad_flash_txt, :chip}},
            {:bad_bundle, "b.zip", {:sha256_mismatch, "x.img"}},
            {:bad_bundle, "b.zip", {:part_mismatch, "atomvm-esp32.bin", 0x10000}},
            {:bad_bundle, "b.zip", {:chip, "esp32", "esp32s3"}},
            {:bad_bundle, "b.zip", :other},
            {:stamp_mismatch, "b.zip", "a+1", "a+2"},
            {:chip_mismatch, "x.img", "esp32", "ESP32-S3"},
            {:flash_offset_conflict, "x.img", 0x1000, 0x0},
            {:unknown_flash_offset, "esp32x9"},
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

  defp factory_release do
    %{
      "tag_name" => "nightly-0.7",
      "prerelease" => false,
      "draft" => false,
      "published_at" => "2026-09-15T22:35:19Z",
      "body" => @factory_body,
      "assets" => [
        %{
          "name" => "#{@stem}.zip",
          "size" => 11_288_674,
          "browser_download_url" =>
            "https://github.com/atomvm/atomvm-esp32-firmware-factory/releases/download/nightly-0.7/#{@stem}.zip",
          "digest" => "sha256:688f3c59753366405f33e09ad45fd1eb5ef6f3f98a60a8586dfd9bc0c4ab65c0",
          "updated_at" => "2026-09-15T22:35:04Z",
          "content_type" => "application/zip"
        }
      ]
    }
  end

  defp parts do
    [
      {"bootloader.bin", 0x0, <<0xE9, 1, 2, 3>> <> :binary.copy(<<0xAB>>, 20)},
      {"partition-table.bin", 0x40, <<0xAA, 0x50>> <> :binary.copy(<<0x01>>, 30)},
      {"atomvm-esp32.bin", 0x80, <<0xE9>> <> :binary.copy(<<0xCD>>, 63)},
      {"esp32boot.avm", 0x100, "#!/usr/bin/env AtomVM\n" <> :binary.copy(<<0x42>>, 10)}
    ]
  end

  defp image_bytes(parts \\ parts()) do
    Enum.reduce(parts, <<>>, fn {_name, offset, data}, image ->
      image <> :binary.copy(<<0xFF>>, offset - byte_size(image)) <> data
    end)
  end

  defp sdkconfig do
    "CONFIG_IDF_TARGET=\"esp32s3\"\nCONFIG_APP_PROJECT_VER=\"#{@stamp}\"\nCONFIG_SPIRAM=y\n"
  end

  defp partitions_csv do
    "# Name, Type, SubType, Offset, Size\nnvs, data, nvs, 0x9000, 0x6000,\nmain.avm, data, phy, 0x250000, 0x100000\n"
  end

  defp flash_txt(chip) do
    """
    AtomVM firmware image: #{@stem}.img
    Chip: #{chip}
    AtomVM build: #{@stamp}
    ESP-IDF: 5.5.4
    Flash offset: 0x0
    Application partition (main.avm): 0x250000

    Install
    -------

    Flash:
      esptool.py --chip #{chip} --port /dev/ttyUSB0 --baud 921600 \\
        --before default_reset --after hard_reset write_flash \\
        0x0 #{@stem}.img

    Update an existing AtomVM installation
    --------------------------------------

      esptool.py --chip #{chip} --port /dev/ttyUSB0 --baud 921600 --after no_reset \\
        verify_flash 0x40 partition-table.bin && \\
      esptool.py --chip #{chip} --port /dev/ttyUSB0 --baud 921600 \\
        --before default_reset --after hard_reset write_flash \\
        0x80 atomvm-esp32.bin 0x100 esp32boot.avm

    Contents
    --------

    The binaries are the parts of the image, byte for byte, at these offsets:
      0x0       bootloader.bin
      0x40      partition-table.bin
      0x80      atomvm-esp32.bin
      0x100     esp32boot.avm

    Debugging
    ---------

    atomvm-esp32.elf holds the symbols of this image.
    """
  end

  defp members(opts \\ []) do
    parts = Keyword.get(opts, :parts, parts())
    image = image_bytes()

    summed =
      [
        {"#{@stem}.img", image},
        {"sdkconfig", sdkconfig()},
        {"partitions.csv", partitions_csv()},
        {"FLASH.txt",
         Keyword.get_lazy(opts, :flash_txt, fn ->
           flash_txt(Keyword.get(opts, :chip, "esp32s3"))
         end)}
      ] ++
        for({name, _offset, data} <- parts, do: {name, data}) ++
        [{"atomvm-esp32.elf", "elf"}, {"atomvm-esp32.map", "map"}]

    sha = fn data -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) end
    sidecar = {"#{@stem}.img.sha256", "#{sha.(image)}  #{@stem}.img\n"}

    sums =
      {"SHA256SUMS", Enum.map_join(summed, fn {name, data} -> "#{sha.(data)}  #{name}\n" end)}

    [hd(summed), sidecar | tl(summed)] ++ [sums]
  end

  defp bundle, do: zip(members())

  defp zip(members) do
    entries = Enum.map(members, fn {name, data} -> {String.to_charlist(name), data} end)
    {:ok, {_name, zip}} = :zip.create(~c"b.zip", entries, [:memory])
    zip
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
