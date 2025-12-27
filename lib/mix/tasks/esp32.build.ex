defmodule Mix.Tasks.Atomvm.Esp32.Build do
  @moduledoc """
  Mix task for building AtomVM for ESP32 from source.

  Builds AtomVM from a local repository or git URL using ESP-IDF.

  ## Requirements

  **General requirements**
    * Erlang/OTP (27 or later)
    * Elixir (1.18 or later)
    * Git

  **Without Docker:**
    * CMake (3.13 or later)
    * Ninja (preferred) or Make
    * ESP-IDF (v5.5.2 recommended)

  **With Docker (--use-docker flag):**
    * Docker
    * Note: Docker build support requires AtomVM main branch from Jan 2, 2026 or later (https://github.com/atomvm/AtomVM/commit/2a4f0d0fe100ef6d440bef86eabfd08c5b290f6c).
      Previous AtomVM versions must be built with the local ESP-IDF toolchain installed.

  ## Options

    * `--atomvm-path` - Path to local AtomVM repository (optional, overrides URL if both provided)
    * `--atomvm-url` - Git URL to clone AtomVM from (optional, defaults to AtomVM/AtomVM main branch)
    * `--ref` - Git reference to checkout - branch, tag, commit SHA, or PR (e.g. `pr/1234` or `pull/1234/head`) (default: main)
    * `--chip` - Target chip(s), comma-separated for multiple (default: esp32, options: esp32, esp32s2, esp32s3, esp32c2, esp32c3, esp32c6, esp32h2, esp32p4)
    * `--idf-path` - Path to idf.py executable (default: idf.py)
    * `--use-docker` - Use ESP-IDF Docker image instead of local installation
    * `--idf-version` - ESP-IDF version for Docker image (default: v5.5.2)
    * `--clean` - Clean build directory before building
    * `--mbedtls-prefix` - Path to custom MbedTLS installation (optional, falls back to MBEDTLS_PREFIX env var)

  ## Examples

      # Build from local repository
      mix atomvm.esp32.build --atomvm-path /path/to/AtomVM

      # Build from git URL
      mix atomvm.esp32.build --atomvm-url https://github.com/atomvm/AtomVM --ref main

      # Build from specific tag
      mix atomvm.esp32.build --atomvm-url https://github.com/atomvm/AtomVM --ref v0.6.5

      # Build from specific commit
      mix atomvm.esp32.build --atomvm-url https://github.com/atomvm/AtomVM --ref abc123def

      # Build for specific chip with clean build
      mix atomvm.esp32.build --atomvm-path /path/to/AtomVM --chip esp32s3 --clean

      # Build using Docker (relative path with ./ is important)
      mix atomvm.esp32.build --atomvm-path ./_build/atomvm_source/AtomVM/ --use-docker --chip esp32s3

      # Build using Docker with specific IDF version
      mix atomvm.esp32.build --atomvm-path ./_build/atomvm_source/AtomVM/ --use-docker --idf-version v5.5.2 --chip esp32s3

      # Build with custom MbedTLS
      mix atomvm.esp32.build --atomvm-path /path/to/AtomVM --mbedtls-prefix /usr/local/opt/mbedtls@3

      # Build from a pull request (shorthand)
      mix atomvm.esp32.build --ref pr/1234

      # Build from a pull request (full refspec)
      mix atomvm.esp32.build --ref pull/1234/head --chip esp32s3

      # Build for multiple chips
      mix atomvm.esp32.build --chip esp32,esp32s3,esp32c6

  """
  use Mix.Task

  @shortdoc "Build AtomVM for ESP32 from source"

  @default_chip "esp32"
  @default_ref "main"
  @default_atomvm_url "https://github.com/atomvm/AtomVM"
  @default_idf_path "idf.py"
  @default_idf_version "v5.5.2"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          atomvm_path: :string,
          atomvm_url: :string,
          ref: :string,
          chip: :string,
          idf_path: :string,
          use_docker: :boolean,
          idf_version: :string,
          clean: :boolean,
          mbedtls_prefix: :string
        ]
      )

    atomvm_path = Keyword.get(opts, :atomvm_path)
    atomvm_url = Keyword.get(opts, :atomvm_url, @default_atomvm_url)
    ref = Keyword.get(opts, :ref, @default_ref)
    idf_path = Keyword.get(opts, :idf_path, @default_idf_path)
    use_docker = Keyword.get(opts, :use_docker, false)
    idf_version = Keyword.get(opts, :idf_version, @default_idf_version)
    clean = Keyword.get(opts, :clean, false)

    chips =
      opts
      |> Keyword.get(:chip, @default_chip)
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    # Get mbedtls_prefix from option or environment variable
    mbedtls_prefix =
      Keyword.get(opts, :mbedtls_prefix) || System.get_env("MBEDTLS_PREFIX")

    # Use --atomvm-path, --atomvm-url, or default to AtomVM/AtomVM main branch
    atomvm_path =
      cond do
        atomvm_path ->
          atomvm_path

        true ->
          ExAtomVM.AtomVMBuilder.clone_or_update_repo(atomvm_url, ref)
      end

    # Verify AtomVM path exists
    unless File.dir?(atomvm_path) do
      IO.puts("Error: AtomVM path does not exist: #{atomvm_path}")
      exit({:shutdown, 1})
    end

    chips_label = Enum.join(chips, ", ")

    IO.puts("""

    Building AtomVM from source
    Repository: #{atomvm_path}
    Chip(s): #{chips_label}
    Clean build: #{clean}

    """)

    with :ok <- check_esp_idf(idf_path, use_docker, idf_version),
         :ok <- ExAtomVM.AtomVMBuilder.build_generic_unix(atomvm_path, mbedtls_prefix, clean) do
      results =
        chips
        |> Enum.with_index(1)
        |> Enum.map(fn {chip, index} ->
          if length(chips) > 1 do
            IO.puts("\n━━━ Building chip #{index}/#{length(chips)}: #{chip} ━━━\n")
          end

          force_clean = index > 1 or clean

          case build_atomvm(atomvm_path, chip, idf_path, idf_version, use_docker, force_clean) do
            :ok ->
              build_dir = Path.join([atomvm_path, "src", "platforms", "esp32", "build"])
              src_img = Path.join([build_dir, "atomvm-#{chip}.img"])
              img = save_image(src_img, chip)
              {chip, :ok, img}

            {:error, reason} ->
              {chip, :error, reason}
          end
        end)

      print_summary(results)

      if Enum.any?(results, fn {_, status, _} -> status == :error end) do
        exit({:shutdown, 1})
      end
    else
      {:error, reason} ->
        IO.puts("Error: #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp print_summary(results) do
    IO.puts("\n━━━ Build Summary ━━━\n")

    cwd = File.cwd!()

    Enum.each(results, fn
      {chip, :ok, img} ->
        if File.exists?(img) do
          IO.puts("  ✅ #{chip}: #{img}")
        else
          IO.puts("  ⚠️  #{chip}: built but image not found at #{img}")
        end

      {chip, :error, reason} ->
        IO.puts("  ❌ #{chip}: #{reason}")
    end)

    successful =
      Enum.filter(results, fn {_, status, img} -> status == :ok and File.exists?(img) end)

    if successful != [] do
      IO.puts("\nTo flash a specific image:")

      Enum.each(successful, fn {_chip, _, img} ->
        IO.puts("  mix atomvm.esp32.install --image #{relative_path(img, cwd)}")
      end)
    end

    IO.puts("")
  end

  defp relative_path(path, cwd) do
    "./#{Path.relative_to(path, cwd)}"
  end

  defp save_image(src_img, chip) do
    output_dir = Path.join([File.cwd!(), "_build", "atomvm_images"])
    File.mkdir_p!(output_dir)
    dest_img = Path.join(output_dir, "atomvm-#{chip}.img")

    if File.exists?(src_img) do
      File.cp!(src_img, dest_img)
      dest_img
    else
      src_img
    end
  end

  defp check_esp_idf(idf_path, use_docker, idf_version) do
    if use_docker do
      case System.find_executable("docker") do
        nil ->
          {:error,
           """
           Docker not found. Please install Docker:

           https://docs.docker.com/get-docker/
           """}

        docker_path ->
          IO.puts("Found Docker: #{docker_path}")
          IO.puts("Using ESP-IDF Docker image: espressif/idf:#{idf_version}")
          :ok
      end
    else
      case System.find_executable(idf_path) do
        nil ->
          {:error,
           """
           ESP-IDF not found. Please install and set up ESP-IDF:

           https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/

           Or use --use-docker to build with Docker instead.
           """}

        idf_path_found ->
          IO.puts("Found ESP-IDF: #{idf_path_found}")
          :ok
      end
    end
  end

  defp configure_elixir_partitions(platform_dir) do
    # Per AtomVM docs: Add partition config to sdkconfig.defaults before building
    sdkconfig_defaults = platform_dir |> Path.join("sdkconfig.defaults")

    IO.puts("Configuring Elixir partition table (partitions-elixir.csv)...")

    # Read existing defaults or create empty
    content =
      if File.exists?(sdkconfig_defaults) do
        File.read!(sdkconfig_defaults)
      else
        ""
      end

    # Check if partition config already exists
    if not String.contains?(content, "CONFIG_PARTITION_TABLE_CUSTOM_FILENAME") do
      # Append Elixir partition configuration
      new_content =
        content <> "\nCONFIG_PARTITION_TABLE_CUSTOM_FILENAME=\"partitions-elixir.csv\"\n"

      File.write!(sdkconfig_defaults, new_content)
      IO.puts("✓ Added partitions-elixir.csv to sdkconfig.defaults")
    else
      # Replace existing config
      new_content =
        content
        |> String.replace(
          ~r/CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="[^"]+"/,
          ~s(CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions-elixir.csv")
        )

      File.write!(sdkconfig_defaults, new_content)
      IO.puts("✓ Updated sdkconfig.defaults to use partitions-elixir.csv")
    end
  end

  defp build_atomvm(atomvm_path, chip, idf_path, idf_version, use_docker, clean) do
    build_dir = Path.join([atomvm_path, "src", "platforms", "esp32", "build"])
    platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])

    # Copy idf_component.yml into build tree if the user has one in their project root
    idf_component_yml = Path.join(File.cwd!(), "idf_component.yml")

    idf_component_example = Path.join(File.cwd!(), "idf_component.yml.example")

    if File.exists?(idf_component_yml) do
      dest_path = Path.join([platform_dir, "main", "idf_component.yml"])
      IO.puts("Copying idf_component.yml to #{dest_path}...")
      File.cp!(idf_component_yml, dest_path)
    else
      unless File.exists?(idf_component_example) do
        example_src = Application.app_dir(:exatomvm, "priv/idf_component.yml.example")
        File.cp!(example_src, idf_component_example)
      end

      IO.puts(
        "Hint: To add ESP-IDF components (e.g. NIFs), rename the example in your project root:\n" <>
          "      mv idf_component.yml.example idf_component.yml"
      )
    end

    # Copy dependencies.lock if it exists in the project root
    dependencies_lock = Path.join(File.cwd!(), "dependencies.lock")

    if File.exists?(dependencies_lock) do
      dest_path = Path.join(platform_dir, "dependencies.lock")
      IO.puts("Copying dependencies.lock to #{dest_path}...")
      File.cp!(dependencies_lock, dest_path)
    end

    if clean and File.dir?(build_dir) do
      IO.puts("Cleaning build directory...")
      File.rm_rf!(build_dir)
    end

    IO.puts("Configuring build for #{chip}...")

    # Configure Elixir partition table in sdkconfig.defaults BEFORE set-target
    configure_elixir_partitions(platform_dir)

    # Set target chip
    {_output, status} =
      if use_docker do
        run_idf_docker(idf_version, atomvm_path, platform_dir, ["set-target", chip])
      else
        System.cmd(idf_path, ["set-target", chip],
          cd: platform_dir,
          stderr_to_stdout: true,
          into: IO.stream(:stdio, :line)
        )
      end

    case status do
      0 ->
        # Reconfigure to ensure partition table settings are applied
        IO.puts("Reconfiguring to apply Elixir partitions...")

        {_output, status} =
          if use_docker do
            run_idf_docker(idf_version, atomvm_path, platform_dir, ["reconfigure"])
          else
            System.cmd(idf_path, ["reconfigure"],
              cd: platform_dir,
              stderr_to_stdout: true,
              into: IO.stream(:stdio, :line)
            )
          end

        status =
          case status do
            0 ->
              IO.puts("Building AtomVM... (this may take several minutes)")

              {_output, build_status} =
                if use_docker do
                  run_idf_docker(idf_version, atomvm_path, platform_dir, ["build"])
                else
                  System.cmd(idf_path, ["build"],
                    cd: platform_dir,
                    stderr_to_stdout: true,
                    into: IO.stream(:stdio, :line)
                  )
                end

              if build_status == 0 do
                # Copy dependencies.lock back to project root if it was created/updated
                repo_dependencies_lock = Path.join(platform_dir, "dependencies.lock")

                if File.exists?(repo_dependencies_lock) do
                  dest_path = Path.join(File.cwd!(), "dependencies.lock")
                  IO.puts("Updating dependencies.lock in project root...")
                  File.cp!(repo_dependencies_lock, dest_path)
                end
              end

              build_status

            _ ->
              status
          end

        case status do
          0 ->
            # Use absolute paths to avoid issues with relative paths
            abs_atomvm_path = Path.expand(atomvm_path)
            abs_build_dir = Path.expand(build_dir)
            mkimage_script = Path.join([abs_build_dir, "mkimage.sh"])

            IO.puts("Creating flashable image...")
            # TODO: Remove --boot flag when AtomVM#1163 is merged
            boot_avm =
              Path.join([abs_atomvm_path, "build", "libs", "esp32boot", "elixir_esp32boot.avm"])

            {_output, status} =
              System.cmd("sh", [mkimage_script, "--boot", boot_avm],
                cd: abs_build_dir,
                stderr_to_stdout: true,
                into: IO.stream(:stdio, :line)
              )

            case status do
              0 ->
                :ok

              _ ->
                {:error, "Failed to create image"}
            end

          _ ->
            {:error, "Build failed"}
        end

      _ ->
        {:error, "Failed to set target chip"}
    end
  end

  defp run_idf_docker(idf_version, atomvm_path, platform_dir, idf_args) do
    # Calculate the relative path from atomvm_path to platform_dir
    relative_dir = Path.relative_to(platform_dir, atomvm_path)

    # Build docker command
    docker_args =
      [
        "run",
        "--rm",
        "-v",
        "#{atomvm_path}:/project",
        "-w",
        "/project/#{relative_dir}",
        "espressif/idf:#{idf_version}",
        "idf.py"
      ] ++ idf_args

    System.cmd("docker", docker_args,
      stderr_to_stdout: true,
      into: IO.stream(:stdio, :line)
    )
  end
end
