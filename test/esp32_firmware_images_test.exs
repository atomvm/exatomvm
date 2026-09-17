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

  describe "connected_chip/1" do
    test "is the chip the connected boards share" do
      s3 = %{"chip_family_name" => "ESP32-S3", "port" => "/dev/ttyACM0"}
      c6 = %{"chip_family_name" => "ESP32-C6", "port" => "/dev/ttyACM1"}

      assert Images.connected_chip([s3]) == {:ok, "esp32s3"}
      assert Images.connected_chip([s3, %{s3 | "port" => "/dev/ttyACM2"}]) == {:ok, "esp32s3"}
      assert Images.connected_chip([]) == {:error, :no_board}
      assert Images.connected_chip([s3, c6]) == {:error, {:several_chips, ["esp32s3", "esp32c6"]}}
    end

    test "its errors point at --chip" do
      for reason <- [:no_board, {:several_chips, ["esp32s3", "esp32c6"]}] do
        assert Images.format_error(reason) =~ "--chip"
      end

      assert Images.format_error({:several_chips, ["esp32s3", "esp32c6"]}) =~ "esp32s3, esp32c6"
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
               "kiosk (local image, unknown)",
               "  offset:   0x0"
             ]

      assert [warning] = Images.warnings(image, "esp32s3")
      assert warning =~ "not known"
    end
  end

  describe "classify_releases/1" do
    test "keeps the newest stable release and the prereleases newer than it" do
      releases = [
        release("v0.7.0-alpha.1", prerelease: true),
        Map.put(release("v0.7.0-alpha.2", prerelease: true), "draft", true),
        release("v0.7.0-alpha.0", prerelease: true),
        release("v0.6.6"),
        release("v0.6.5"),
        release("v0.6.0-rc.0", prerelease: true)
      ]

      assert %{
               stable: %{"tag_name" => "v0.6.6"},
               prereleases: [%{"tag_name" => "v0.7.0-alpha.1"}, %{"tag_name" => "v0.7.0-alpha.0"}]
             } = Images.classify_releases(releases)

      assert %{stable: nil, prereleases: [_, _]} =
               Images.classify_releases(Enum.take(releases, 3))
    end
  end

  describe "listing_sections/2" do
    test "titles the AtomVM sections by release" do
      releases = [release("v0.7.0-alpha.1", prerelease: true), release("v0.6.6")]

      assert [
               %{kind: :stable, title: "Stable release v0.6.6 (2025-06-23)", images: [_ | _]},
               %{kind: :prerelease, title: "Prerelease v0.7.0-alpha.1 (2025-06-23)"}
             ] = Images.listing_sections(:atomvm, releases)
    end

    test "puts every published factory build in one section" do
      releases = [factory_release(), Map.put(factory_release(), "draft", true)]

      assert [
               %{
                 kind: :nightly,
                 title: "Nightly builds (atomvm-esp32-firmware-factory)",
                 images: [%{name: @stem}]
               }
             ] =
               Images.listing_sections(:factory, releases)
    end
  end

  describe "render_list/2" do
    setup do
      sections =
        Images.listing_sections(:atomvm, [
          release("v0.7.0-alpha.1", prerelease: true),
          release("v0.6.6")
        ]) ++
          Images.listing_sections(:factory, [factory_release()]) ++
          [%{kind: :local, title: "Local images", images: local_images()}]

      %{sections: sections}
    end

    test "lists the images for the filtered chip and counts the others", %{sections: sections} do
      header = ["Connected: ESP32-S3 on /dev/ttyACM0, installed: v0.6.6"]
      output = Images.render_list(sections, filter: ["esp32s3"], header: header)
      lines = String.split(output, "\n")

      assert hd(lines) == hd(header)
      assert "Showing images for esp32s3; pass --chip all to list every image." in lines
      assert "Stable release v0.6.6 (2025-06-23)" in lines
      assert "Prerelease v0.7.0-alpha.1 (2025-06-23)" in lines
      assert Enum.any?(lines, &(&1 =~ ~r/^  AtomVM-esp32s3-elixir-v0.6.6 +Elixir +2.1 MB$/))
      assert Enum.any?(lines, &(&1 =~ ~r/^  AtomVM-esp32s3-v0.6.6 +Erlang only +2.1 MB$/))
      refute Enum.any?(lines, &(&1 =~ "AtomVM-esp32-elixir-v0.6.6"))
      assert Enum.any?(lines, &(&1 =~ ~r/^  #{@stem} +Erlang only +10.8 MB$/))
      assert "    build #{@stamp} (2026-09-15), features: atomgl, ipv6, libsodium, psram" in lines
      assert "Local images" in lines

      assert Enum.any?(
               lines,
               &(&1 =~
                   ~r|^  firmware_images/AtomVM-esp32s3-elixir-v0.6.6.img +Elixir +2.1 MB  cached$|)
             )

      assert Enum.any?(
               lines,
               &(&1 =~
                   ~r|^  firmware_images/#{@stem}\+20260914.7ab12cd.zip +Erlang only +10.5 MB  cached, no longer published$|)
             )

      assert Enum.any?(
               lines,
               &(&1 =~
                   ~r|^  _build/atomvm_images/atomvm-esp32s3-elixir.img +Elixir +1.9 MB  built by mix atomvm.esp32.build$|)
             )

      assert "12 images for other chips not shown." in lines
      assert "  mix atomvm.esp32.install --image <name or path>" in lines

      assert List.last(lines) ==
               "None of these fits? mix atomvm.esp32.build builds a custom image from source."

      refute output =~ ~r/[^\x00-\x7F]/
    end

    test "lists every image without a filter", %{sections: sections} do
      output = Images.render_list(sections)
      refute output =~ "not shown"
      refute output =~ "Showing images"
      assert output =~ "AtomVM-esp32-elixir-v0.6.6"
      assert output =~ "AtomVM-esp32p4_pre-elixir-v0.7.0-alpha.1"
    end

    test "filters the variants of a chip by their base chip", %{sections: sections} do
      output = Images.render_list(sections, filter: ["esp32p4"])
      assert output =~ "AtomVM-esp32p4-elixir-v0.7.0-alpha.1"
      assert output =~ "AtomVM-esp32p4_pre-elixir-v0.7.0-alpha.1"

      output = Images.render_list(sections, filter: ["esp32p4_pre"])
      refute output =~ "AtomVM-esp32p4-elixir-v0.7.0-alpha.1"
      assert output =~ "AtomVM-esp32p4_pre-elixir-v0.7.0-alpha.1"
    end
  end

  describe "without_extracted/1" do
    test "lists a cached bundle without the image extracted next to it" do
      images =
        Enum.map(
          [
            "firmware_images/#{@stem}+20260915.02e1603.zip",
            "firmware_images/#{@stem}+20260915.02e1603.img",
            "firmware_images/#{@stem}+20260914.7ab12cd.img",
            "firmware_images/AtomVM-esp32s3-elixir-v0.6.6.img"
          ],
          &Images.local_image/1
        )

      assert Enum.map(Images.without_extracted(images), & &1.file) == [
               "#{@stem}+20260915.02e1603.zip",
               "#{@stem}+20260914.7ab12cd.img",
               "AtomVM-esp32s3-elixir-v0.6.6.img"
             ]
    end
  end

  describe "format_size/1" do
    test "rounds to a tenth of a megabyte, or to kilobytes" do
      assert Images.format_size(2_197_764) == "2.1 MB"
      assert Images.format_size(315_504) == "309 KB"
      assert Images.format_size(nil) == ""
    end
  end

  describe "parse_repo_arg/1" do
    test "accepts OWNER/REPO and the URL of a repository" do
      for arg <- [
            "acme/atomvm-builds",
            "https://github.com/acme/atomvm-builds",
            "https://github.com/acme/atomvm-builds/releases/",
            "github.com/acme/atomvm-builds.git",
            " acme/atomvm-builds "
          ] do
        assert Images.parse_repo_arg(arg) == {:ok, "acme/atomvm-builds"}, arg
      end
    end

    test "rejects anything else" do
      for arg <- ["acme", "https://gitlab.com/acme/builds", "acme/builds/extra", "acme//x", ""] do
        assert Images.parse_repo_arg(arg) == :error, arg
      end
    end
  end

  describe "release_images/2 on a repository of custom builds" do
    test "keeps the images that do not follow the naming convention" do
      source = {:repo, "acme/atomvm-builds"}
      images = Images.release_images(custom_release("v1.2.0"), source)
      assert Enum.map(images, & &1.name) == ["AtomVM-esp32s3-elixir-lvgl-v1.2.0", "esp32s3-kiosk"]

      assert %{
               file: "esp32s3-kiosk.img",
               kind: :img,
               chip: nil,
               elixir?: nil,
               version: "v1.2.0",
               channel: :custom,
               stamp: nil,
               source: ^source,
               sha256_url:
                 "https://github.com/acme/atomvm-builds/releases/download/v1.2.0/esp32s3-kiosk.img.sha256"
             } = List.last(images)

      assert %{chip: "esp32s3", elixir?: true, features: ["lvgl"], channel: :stable} = hd(images)
    end

    test "stamps the images of a rolling tag with their upload date" do
      [_, kiosk] = Images.release_images(custom_release("latest"), {:repo, "acme/atomvm-builds"})
      assert kiosk.stamp == "latest+20250623"
      assert Images.cached_file_name(kiosk) == "esp32s3-kiosk+20250623.img"
    end

    test "never lists custom names from the default sources" do
      assert [%{name: "AtomVM-esp32s3-elixir-lvgl-v1.2.0"}] =
               Images.release_images(custom_release("v1.2.0"))
    end
  end

  describe "listing_sections/2 and render_list/2 with a repository" do
    test "lists the builds of each release, custom names installable by name" do
      source = {:repo, "acme/atomvm-builds"}

      assert [
               %{
                 kind: :custom,
                 title: "Custom builds (acme/atomvm-builds), release v1.2.0 (2025-06-23)"
               } = section
             ] =
               Images.listing_sections(source, [custom_release("v1.2.0")])

      output = Images.render_list([section], filter: ["esp32s3"])
      assert output =~ ~r/^  AtomVM-esp32s3-elixir-lvgl-v1.2.0 +Elixir +2.1 MB$/m
      assert output =~ ~r/^  esp32s3-kiosk.img +unknown +2.1 MB  install by name with --repo$/m
      refute output =~ "not shown"
    end
  end

  describe "find_in_releases/3" do
    test "finds a name in the newest release that has it, whatever its case" do
      source = {:repo, "acme/atomvm-builds"}
      releases = [custom_release("v1.3.0"), custom_release("v1.2.0")]

      assert {:ok, %{tag: "v1.3.0"}} = Images.find_in_releases(releases, "ESP32S3-KIOSK", source)

      assert {:ok, %{tag: "v1.3.0", name: "AtomVM-esp32s3-elixir-lvgl-v1.3.0"}} =
               Images.find_in_releases(releases, "AtomVM-esp32s3-elixir-lvgl-v1.3.0", source)

      assert {:error, {:unknown_image, "other", ^source}} =
               Images.find_in_releases(releases, "other", source)
    end
  end

  describe "classify_image_arg/2 with a repository" do
    test "takes any name as a custom build to look up" do
      assert {:name, %{name: "esp32s3-kiosk", file: "esp32s3-kiosk.img", channel: :custom}} =
               Images.classify_image_arg("esp32s3-kiosk.img", true)

      assert {:name, %{name: "AtomVM-esp32s3-elixir-v0.6.6", channel: :stable}} =
               Images.classify_image_arg("AtomVM-esp32s3-elixir-v0.6.6", true)

      assert Images.classify_image_arg("esp32s3-kiosk.img", false) == :error
    end
  end

  describe "cache_dir/1" do
    test "gives a repository of custom builds a subdirectory of its own" do
      assert Images.cache_dir({:repo, "acme/atomvm-builds"}) ==
               Path.join(Images.cache_dir(), "acme-atomvm-builds")

      assert Images.cache_dir(:factory) == Images.cache_dir()
    end
  end

  describe "slice_image/2" do
    test "cuts the app and the boot library out along the embedded partition table" do
      assert {:ok, parts} = Images.slice_image(plain_image(), 0x1000)
      assert parts.table == partition_table_bin()
      assert {:ok, %{idf_ver: "v5.4.1"}} = Images.bootloader_desc(parts.bootloader)
      assert parts.app == {0x10000, "factory.bin", app_bytes()}
      assert parts.lib == {0x30000, "boot.avm", lib_bytes()}
    end

    test "drops the trailing 0xFF of a slice, which erased flash reads anyway" do
      image = plain_image(app: app_bytes() <> <<0xFF, 0xFF>>)
      assert {:ok, %{app: {_, _, app}}} = Images.slice_image(image, 0x1000)
      assert app == app_bytes()
    end

    test "rejects an image without the expected layout" do
      assert Images.slice_image(<<0xE9, 1, 2>>, 0x1000) == {:error, {:bad_image, :truncated}}

      erased = :binary.copy(<<0xFF>>, 0x40000)

      assert Images.slice_image(erased, 0x1000) ==
               {:error, {:partition_mismatch, {:missing, "factory"}}}

      zeros = :binary.copy(<<0>>, 0x40000)

      assert {:error, {:partition_mismatch, {:unreadable, :image, _}}} =
               Images.slice_image(zeros, 0x1000)

      image = plain_image(partitions: List.keydelete(partitions(), "boot.avm", 0))

      assert Images.slice_image(image, 0x1000) ==
               {:error, {:partition_mismatch, {:missing, "boot.avm"}}}

      image = plain_image(lib: <<>>)
      assert Images.slice_image(image, 0x1000) == {:error, {:bad_image, {:no_data, "boot.avm"}}}
    end
  end

  describe "bundle_update_parts/1" do
    test "takes the parts of a bundle at the offsets FLASH.txt states" do
      {:ok, bundle} = Images.verify_bundle(bundle(), "b.zip", @stamp)
      assert {:ok, parts} = Images.bundle_update_parts(bundle)
      assert parts.bootloader == part_data("bootloader.bin")
      assert parts.table == part_data("partition-table.bin")
      assert parts.app == {0x80, "atomvm-esp32.bin", part_data("atomvm-esp32.bin")}
      assert parts.lib == {0x100, "esp32boot.avm", part_data("esp32boot.avm")}
    end

    test "slices the image of a bundle of the first format" do
      flash_txt =
        flash_txt("esp32s3") |> String.split("Update an existing") |> hd() |> String.trim()

      {:ok, bundle} =
        Images.verify_bundle(zip(Enum.take(members(flash_txt: flash_txt), 5)), "b.zip", nil)

      assert {:error, {:bad_image, :truncated}} = Images.bundle_update_parts(bundle)
    end
  end

  describe "bootloader_desc/1 and compare_idf/2" do
    test "reads the ESP-IDF version of a bootloader" do
      assert Images.bootloader_desc(bootloader_bytes("v5.5.4")) == {:ok, %{idf_ver: "v5.5.4"}}
      assert Images.bootloader_desc(:binary.copy(<<0xE9>>, 0x70)) == :error
      assert Images.bootloader_desc(<<0xE9, 0, 0>>) == :error
    end

    test "compares versions with or without the v" do
      assert Images.compare_idf("v5.5.4", "v5.4.1") == :gt
      assert Images.compare_idf("5.4.1", "v5.4.1") == :eq
      assert Images.compare_idf("v5.4", "v5.4.1") == :lt
      assert Images.compare_idf("v5.5.4", nil) == :unknown
      assert Images.compare_idf("main", "v5.5.4") == :unknown
    end
  end

  describe "check_bootloader/2" do
    test "refuses a board bootloader newer than the image, warns when unknown" do
      assert {:ok, %{board: "v5.4.1", image: "v5.5.4", warning: nil}} =
               Images.check_bootloader(bootloader_bytes("v5.4.1"), bootloader_bytes("v5.5.4"))

      assert {:ok, %{warning: nil}} =
               Images.check_bootloader(bootloader_bytes("v5.5.4"), bootloader_bytes("v5.5.4"))

      assert {:error, {:bootloader_newer, "v5.5.4", "v5.4.1"}} =
               Images.check_bootloader(bootloader_bytes("v5.5.4"), bootloader_bytes("v5.4.1"))

      assert {:ok, %{board: nil, image: "v5.5.4", warning: warning}} =
               Images.check_bootloader(<<0xE9, 0, 0>>, bootloader_bytes("v5.5.4"))

      assert warning =~ "cannot be compared"
    end
  end

  describe "check_update_layout/4" do
    test "requires the factory and boot.avm partitions to match, and the parts to fit" do
      table = partition_table_bin()
      assert Images.check_update_layout(table, table, 100, 100) == :ok

      expanded =
        partition_table_bin(
          List.keyreplace(partitions(), "main.avm", 0, {"main.avm", 1, 1, 0x40000, 0x3C0000})
        )

      assert Images.check_update_layout(expanded, table, 100, 100) == :ok

      moved =
        partition_table_bin(
          List.keyreplace(partitions(), "factory", 0, {"factory", 0, 0, 0x10000, 0x30000})
        )

      assert {:error, {:partition_mismatch, {"factory", %{size: 0x30000}, %{size: 0x20000}}}} =
               Images.check_update_layout(moved, table, 100, 100)

      assert Images.check_update_layout(table, table, 0x20001, 100) ==
               {:error, {:part_too_large, "factory", 0x20001, 0x20000}}

      assert Images.check_update_layout(table, table, 100, 0x10001) ==
               {:error, {:part_too_large, "boot.avm", 0x10001, 0x10000}}

      assert {:error, {:partition_mismatch, {:unreadable, :board, _}}} =
               Images.check_update_layout(:binary.copy(<<0>>, 64), table, 1, 1)
    end
  end

  describe "update_summary/4" do
    test "says what an update replaces with what" do
      [image] = Images.release_images(factory_release(), :factory)

      {:ok, parts} =
        Images.bundle_update_parts(elem(Images.verify_bundle(bundle(), "b.zip", @stamp), 1))

      assert Images.update_summary("v0.6.6-dirty", "v5.4.1", image, parts) == [
               "  from:  v0.6.6-dirty (bootloader ESP-IDF v5.4.1)",
               "  to:    #{@stem} (nightly build nightly-0.7, Erlang only), build #{@stamp}",
               "  writes atomvm-esp32.bin at 0x80 and esp32boot.avm at 0x100",
               "The bootloader, the partition table, NVS and main.avm are kept."
             ]

      assert ["  from:  unknown build" | _] = Images.update_summary(nil, nil, image, parts)
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
            {:release_not_found, {:repo, "acme/atomvm-builds"}, nil},
            {:unknown_image, "AtomVM-esp32-v9.9.9", :atomvm},
            {:unknown_image, "kiosk", {:repo, "acme/atomvm-builds"}},
            {:no_image_for_chip, "v1.2.0", "esp32s3", []},
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
            :not_installed,
            {:bad_image, :truncated},
            {:bad_image, {:no_data, "factory"}},
            {:partition_mismatch, {:unreadable, :board, :invalid_partition_table}},
            {:partition_mismatch, {:missing, "boot.avm"}},
            {:partition_mismatch,
             {"factory", %{offset: 0x10000, size: 0x30000}, %{offset: 0x10000, size: 0x20000}}},
            {:part_too_large, "factory", 0x20001, 0x20000},
            {:bootloader_newer, "v5.5.4", "v5.4.1"},
            {:pythonx_error, "Pythonx error occurred: x"},
            :flash_read_failed,
            :no_board,
            {:several_chips, ["esp32", "esp32s3"]},
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

  defp local_images do
    [
      {"firmware_images/AtomVM-esp32s3-elixir-v0.6.6.img", :cache, 2_201_860},
      {"firmware_images/#{@stem}+20260914.7ab12cd.zip", :cache, 11_000_000},
      {"_build/atomvm_images/atomvm-esp32s3-elixir.img", :build, 2_000_000}
    ]
    |> Enum.map(fn {path, source, size} ->
      Map.merge(Images.local_image(path), %{source: source, size: size})
    end)
  end

  defp custom_release(tag) do
    download = "https://github.com/acme/atomvm-builds/releases/download/#{tag}/"

    assets =
      for name <- [
            "AtomVM-esp32s3-elixir-lvgl-#{tag}.img",
            "esp32s3-kiosk.img",
            "esp32s3-kiosk.img.sha256",
            "README.md"
          ] do
        %{asset(tag, name, 2_197_764) | "browser_download_url" => download <> name}
      end

    %{
      "tag_name" => tag,
      "prerelease" => false,
      "draft" => false,
      "published_at" => "2025-06-23T23:04:23Z",
      "body" => "",
      "assets" => assets
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

  defp part_data(name) do
    {^name, _offset, data} = List.keyfind(parts(), name, 0)
    data
  end

  defp partitions do
    [
      {"nvs", 1, 2, 0x9000, 0x6000},
      {"phy_init", 1, 1, 0xF000, 0x1000},
      {"factory", 0, 0, 0x10000, 0x20000},
      {"boot.avm", 1, 1, 0x30000, 0x10000},
      {"main.avm", 1, 1, 0x40000, 0x10000}
    ]
  end

  defp partition_table_bin(partitions \\ partitions()) do
    entries =
      for {name, type, subtype, offset, size} <- partitions, into: <<>> do
        label = String.pad_trailing(name, 16, <<0>>)

        <<0xAA, 0x50, type, subtype, offset::little-32, size::little-32, label::binary,
          0::little-32>>
      end

    md5 = <<0xEB, 0xEB>> <> :binary.copy(<<0xFF>>, 14) <> :crypto.hash(:md5, entries)
    entries <> md5 <> :binary.copy(<<0xFF>>, 0xC00 - byte_size(entries) - 32)
  end

  defp bootloader_bytes(idf_ver) do
    <<0xE9, 3, 2, 0x2F>> <>
      :binary.copy(<<0>>, 0x1C) <>
      <<0x50, 0, 0, 0, 1::little-32>> <>
      String.pad_trailing(idf_ver, 32, <<0>>) <>
      :binary.copy(<<0>>, 24 + 16) <>
      :binary.copy(<<0xAB>>, 64)
  end

  defp app_bytes, do: <<0xE9>> <> :binary.copy(<<0xCD>>, 999)
  defp lib_bytes, do: "#!/usr/bin/env AtomVM\n" <> :binary.copy(<<0x42>>, 500) <> "end\0"

  defp plain_image(opts \\ []) do
    base = 0x1000
    partitions = Keyword.get(opts, :partitions, partitions())
    app = Keyword.get(opts, :app, app_bytes())
    lib = Keyword.get(opts, :lib, lib_bytes())

    at = fn image, offset, data ->
      image <> :binary.copy(<<0xFF>>, offset - base - byte_size(image)) <> data
    end

    <<>>
    |> at.(base, bootloader_bytes("v5.4.1"))
    |> at.(0x8000, partition_table_bin(partitions))
    |> at.(0x10000, app)
    |> at.(0x30000, lib)
  end

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
