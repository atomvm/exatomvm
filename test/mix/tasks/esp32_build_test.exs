defmodule Mix.Tasks.Atomvm.Esp32.BuildTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Atomvm.Esp32.Build

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  test "custom_sdkconfig_paths/2 resolves defaults in given directory", %{tmp_dir: tmp_dir} do
    # 1. Neither base nor chip exists
    assert Build.custom_sdkconfig_paths(Path.join(tmp_dir, "nonexistent"), "esp32s3") == :error

    # 2. Only base exists
    base_file = Path.join(tmp_dir, "my_sdkconfig")
    File.write!(base_file, "CONFIG_TEST=y")
    assert Build.custom_sdkconfig_paths(base_file, "esp32s3") == {:ok, {base_file, nil}}

    # 3. Only chip-specific exists
    File.rm!(base_file)
    chip_file = "#{base_file}.esp32s3"
    File.write!(chip_file, "CONFIG_TEST_CHIP=y")
    assert Build.custom_sdkconfig_paths(base_file, "esp32s3") == {:ok, {nil, chip_file}}

    # 4. Both exist
    File.write!(base_file, "CONFIG_TEST=y")
    assert Build.custom_sdkconfig_paths(base_file, "esp32s3") == {:ok, {base_file, chip_file}}
  end

  test "validate_sdkconfigs/2 performs correct validation checks", %{tmp_dir: tmp_dir} do
    base_file = Path.join(tmp_dir, "valid_sdkconfig")
    chip_file = "#{base_file}.esp32s3"

    # 1. Neither exists
    assert {:error, "SDK config file does not exist:" <> _} =
             Build.validate_sdkconfigs(base_file, "esp32s3")

    # 2. File exists but is empty
    File.touch!(base_file)
    assert {:error, "valid_sdkconfig is empty"} = Build.validate_sdkconfigs(base_file, "esp32s3")

    # 3. File exists but is not a regular file (e.g. a directory)
    File.rm!(base_file)
    File.mkdir!(base_file)

    assert {:error, "valid_sdkconfig exists but is not a regular file"} =
             Build.validate_sdkconfigs(base_file, "esp32s3")

    # Clean up directory
    File.rmdir!(base_file)

    # 4. Valid file
    File.write!(base_file, "CONFIG_TEST=y")
    assert Build.validate_sdkconfigs(base_file, "esp32s3") == :ok

    # 5. Chip-specific file validation
    File.touch!(chip_file)

    assert {:error, "valid_sdkconfig.esp32s3 is empty"} =
             Build.validate_sdkconfigs(base_file, "esp32s3")

    File.write!(chip_file, "CONFIG_CHIP=y")
    assert Build.validate_sdkconfigs(base_file, "esp32s3") == :ok
  end

  test "custom_sdkconfig_paths/2 auto-discovers sdkconfig defaults in cwd", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      refute File.exists?("sdkconfig.defaults")
      assert Build.custom_sdkconfig_paths(nil, "esp32") == :error

      base_file = Path.join(tmp_dir, "sdkconfig.defaults")
      File.write!(base_file, "CONFIG_BASE=y")
      assert Build.custom_sdkconfig_paths(nil, "esp32") == {:ok, {base_file, nil}}

      chip_file = Path.join(tmp_dir, "sdkconfig.defaults.esp32s3")
      File.write!(chip_file, "CONFIG_CHIP=y")
      assert Build.custom_sdkconfig_paths(nil, "esp32s3") == {:ok, {base_file, chip_file}}
    end)
  end

  test "validate_sdkconfigs/2 rejects invalid auto-discovered defaults", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      File.touch!("sdkconfig.defaults")
      assert {:error, "sdkconfig.defaults is empty"} = Build.validate_sdkconfigs(nil, "esp32")

      File.rm!("sdkconfig.defaults")
      File.mkdir!("sdkconfig.defaults")

      assert {:error, "sdkconfig.defaults exists but is not a regular file"} =
               Build.validate_sdkconfigs(nil, "esp32")
    end)
  end

  test "atomvm.esp32.build stages custom defaults after AtomVM chip defaults and restores them",
       %{
         tmp_dir: tmp_dir
       } do
    File.cd!(tmp_dir, fn ->
      atomvm_path = Path.join(tmp_dir, "AtomVM")
      platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])
      target_defaults = Path.join(platform_dir, "sdkconfig.defaults.esp32p4")
      captured_defaults = Path.join(tmp_dir, "captured.defaults")

      File.mkdir_p!(Path.join(platform_dir, "main"))
      File.mkdir_p!(Path.join([atomvm_path, "build", "tools", "packbeam"]))
      File.mkdir_p!(Path.join([atomvm_path, "build", "libs", "esp32boot"]))
      File.write!(Path.join([atomvm_path, "build", "tools", "packbeam", "PackBEAM"]), "")

      File.write!(
        Path.join([atomvm_path, "build", "libs", "esp32boot", "elixir_esp32boot.avm"]),
        ""
      )

      File.write!(target_defaults, "CONFIG_SPIRAM=y\nCONFIG_ATOMVM_CHIP_DEFAULT=y\n")
      File.write!("sdkconfig.defaults", "CONFIG_PROJECT_BASE=y")
      File.write!("sdkconfig.defaults.esp32p4", "# CONFIG_SPIRAM is not set")
      File.write!("idf_component.yml.example", "")

      idf_path = Path.join(tmp_dir, "idf.py")

      File.write!(
        idf_path,
        "#!/bin/sh\ncp sdkconfig.defaults.esp32p4 \"#{captured_defaults}\"\nexit 1\n"
      )

      File.chmod!(idf_path, 0o755)

      capture_io(fn ->
        assert catch_exit(
                 Build.run([
                   "--atomvm-path",
                   atomvm_path,
                   "--idf-path",
                   idf_path,
                   "--chip",
                   "esp32p4"
                 ])
               ) == {:shutdown, 1}
      end)

      assert File.read!(captured_defaults) ==
               "CONFIG_SPIRAM=y\nCONFIG_ATOMVM_CHIP_DEFAULT=y\n\n" <>
                 "# User Custom Defaults\nCONFIG_PROJECT_BASE=y\n" <>
                 "# CONFIG_SPIRAM is not set\n"

      assert File.read!(target_defaults) ==
               "CONFIG_SPIRAM=y\nCONFIG_ATOMVM_CHIP_DEFAULT=y\n"
    end)
  end
end
