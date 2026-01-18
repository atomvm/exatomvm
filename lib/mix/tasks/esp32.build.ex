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
    * `--ref` - Git reference to checkout - branch, tag, or commit SHA (default: main)
    * `--chip` - Target chip (default: esp32, options: esp32, esp32s2, esp32s3, esp32c2, esp32c3, esp32c6, esp32h2, esp32p4)
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
    chip = Keyword.get(opts, :chip, @default_chip)
    idf_path = Keyword.get(opts, :idf_path, @default_idf_path)
    use_docker = Keyword.get(opts, :use_docker, false)
    idf_version = Keyword.get(opts, :idf_version, @default_idf_version)
    clean = Keyword.get(opts, :clean, false)

    # Get mbedtls_prefix from option or environment variable
    mbedtls_prefix =
      Keyword.get(opts, :mbedtls_prefix) || System.get_env("MBEDTLS_PREFIX")

    # Use --atomvm-path, --atomvm-url, or default to AtomVM/AtomVM main branch
    atomvm_path =
      cond do
        atomvm_path ->
          atomvm_path

        atomvm_url ->
          clone_or_update_repo(atomvm_url, ref)
      end

    # Verify AtomVM path exists
    unless File.dir?(atomvm_path) do
      IO.puts("Error: AtomVM path does not exist: #{atomvm_path}")
      exit({:shutdown, 1})
    end

    IO.puts("""

    Building AtomVM for #{chip} from source
    Repository: #{atomvm_path}
    Chip: #{chip}
    Clean build: #{clean}

    """)

    with :ok <- check_esp_idf(idf_path, use_docker, idf_version),
         :ok <- build_generic_unix(atomvm_path, mbedtls_prefix, clean),
         :ok <- copy_avm_libraries(atomvm_path),
         :ok <- build_atomvm(atomvm_path, chip, idf_path, idf_version, use_docker, clean) do
      build_dir = Path.join([atomvm_path, "src", "platforms", "esp32", "build"])
      atomvm_img = Path.join([build_dir, "atomvm-#{chip}.img"])

      if File.exists?(atomvm_img) do
        IO.puts("""

        ✅ Successfully built AtomVM for #{chip}

        Build directory: #{build_dir}

        Flashable image: #{atomvm_img}

        To flash to your device, run:
          mix atomvm.esp32.install --image #{atomvm_img}

        Or use idf.py:
          cd #{Path.dirname(build_dir)}
          idf.py flash

        """)
      else
        IO.puts("""

        ⚠️  Build completed but image file not found at expected location:
        #{atomvm_img}

        Please check the build output above for the actual location.

        """)
      end
    else
      {:error, reason} ->
        IO.puts("Error: #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp clone_or_update_repo(url, ref) do
    cache_dir =
      if Code.ensure_loaded?(Mix.Project) do
        Path.join(Path.dirname(Mix.Project.build_path()), "atomvm_source")
      else
        Path.expand("_build/atomvm_source")
      end

    repo_name = url |> Path.basename() |> String.replace(".git", "")
    repo_path = Path.join(cache_dir, repo_name)

    if File.dir?(Path.join(repo_path, ".git")) do
      update_repo(repo_path, ref)
    else
      clone_repo(url, repo_path, cache_dir, ref)
    end
  end

  defp clone_repo(url, repo_path, cache_dir, ref) do
    IO.puts("Cloning #{url}")
    File.mkdir_p!(cache_dir)

    {output, status} =
      System.cmd("git", ["clone", url, repo_path], stderr_to_stdout: true)

    case status do
      0 ->
        IO.puts(output)
        checkout_ref(repo_path, ref)

      _ ->
        IO.puts("Error cloning repository:\n#{output}")
        exit({:shutdown, 1})
    end
  end

  defp update_repo(repo_path, ref) do
    IO.puts("Updating existing repository at #{repo_path}")

    # Fetch all refs from origin
    {output, status} =
      System.cmd("git", ["fetch", "origin"],
        cd: repo_path,
        stderr_to_stdout: true
      )

    case status do
      0 ->
        IO.puts(output)
        checkout_ref(repo_path, ref)

      _ ->
        IO.puts("Error fetching from repository:\n#{output}")
        exit({:shutdown, 1})
    end
  end

  defp checkout_ref(repo_path, ref) do
    IO.puts("Checking out ref: #{ref}")

    {output, status} =
      System.cmd("git", ["checkout", ref],
        cd: repo_path,
        stderr_to_stdout: true
      )

    case status do
      0 ->
        IO.puts(output)
        pull_if_branch(repo_path, ref)

      _ ->
        IO.puts("Error checking out ref:\n#{output}")
        exit({:shutdown, 1})
    end
  end

  defp pull_if_branch(repo_path, ref) do
    # Check if we're on a branch (not a detached HEAD)
    {_output, status} =
      System.cmd("git", ["symbolic-ref", "-q", "HEAD"],
        cd: repo_path,
        stderr_to_stdout: true
      )

    if status == 0 do
      # We're on a branch, pull latest changes
      IO.puts("Pulling latest changes for branch #{ref}")

      {output, status} =
        System.cmd("git", ["pull", "origin", ref],
          cd: repo_path,
          stderr_to_stdout: true
        )

      case status do
        0 ->
          IO.puts(output)
          repo_path

        _ ->
          IO.puts("Warning: Could not pull changes:\n#{output}")
          repo_path
      end
    else
      # Detached HEAD (tag or commit), no need to pull
      IO.puts("Checked out tag or commit (detached HEAD)")
      repo_path
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

  defp build_generic_unix(atomvm_path, mbedtls_prefix, clean) do

    build_dir = Path.join(atomvm_path, "build")

    # Clean build directory if requested
    if clean and File.dir?(build_dir) do
      IO.puts("Cleaning generic Unix build directory...")
      File.rm_rf!(build_dir)
    end

    # Check if tools and esp32boot already exist
    packbeam_path = Path.join([build_dir, "tools", "packbeam", "PackBEAM"])
    esp32boot_path = Path.join([build_dir, "libs", "esp32boot", "elixir_esp32boot.avm"])

    if File.exists?(packbeam_path) and File.exists?(esp32boot_path) do
      IO.puts("Generic Unix build tools and elixir_esp32boot already exist, skipping...")
      :ok
    else
      IO.puts("Building generic Unix tools and elixir_esp32boot (required for ESP32 build)...")
      File.mkdir_p!(build_dir)

      # Check if ninja is available, fall back to make if not
      {build_tool, cmake_generator} =
        case System.find_executable("ninja") do
          nil ->
            IO.puts("Ninja not found, using Make as build system")
            {"make", []}

          _ninja_path ->
            IO.puts("Using Ninja as build system")
            {"ninja", ["-GNinja"]}
        end

      # Equivalent to: ${MBEDTLS_PREFIX:+-DCMAKE_PREFIX_PATH="$MBEDTLS_PREFIX"}
      mbedtls_args =
        if mbedtls_prefix do
          IO.puts("Using custom MbedTLS from: #{mbedtls_prefix}")
          ["-DCMAKE_PREFIX_PATH=#{mbedtls_prefix}"]
        else
          []
        end

      # Run cmake: cmake .. ${MBEDTLS_PREFIX:+...} -G Ninja -DCMAKE_BUILD_TYPE=Release -DAVM_BUILD_RUNTIME_ONLY=ON
      cmake_args =
        [".."] ++
          mbedtls_args ++
          cmake_generator ++ ["-DCMAKE_BUILD_TYPE=Release", "-DAVM_BUILD_RUNTIME_ONLY=ON"]

      {_output, status} =
        System.cmd("cmake", cmake_args,
          cd: build_dir,
          stderr_to_stdout: true,
          into: IO.stream(:stdio, :line)
        )

      case status do
        0 ->
          IO.puts("Building tools and elixir_esp32boot...")

          {_output, status} =
            System.cmd(build_tool, ["PackBEAM", "elixir_esp32boot", "exavmlib", "atomvmlib"],
              cd: build_dir,
              stderr_to_stdout: true,
              into: IO.stream(:stdio, :line)
            )

          case status do
            0 ->
              IO.puts("Generic Unix tools and elixir_esp32boot built successfully")
              :ok

            _ ->
              {:error, "Failed to build generic Unix tools"}
          end

        _ ->
          {:error, "Failed to configure generic Unix build"}
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

  defp copy_avm_libraries(atomvm_path) do
    avm_deps_dir = File.cwd!() |> Path.join("avm_deps")

    if File.dir?(avm_deps_dir) do
      IO.puts("Removing existing avm_deps folder...")
      File.rm_rf!(avm_deps_dir)
    end

    IO.puts("Creating avm_deps folder and copying libraries...")
    File.mkdir_p!(avm_deps_dir)

    build_libs_dir = atomvm_path |> Path.join("build") |> Path.join("libs")
    avm_files = build_libs_dir |> Path.join("**/*.avm") |> Path.wildcard()

    # Copy each file
    case avm_files do
      [] ->
        IO.puts("Warning: No .avm files found in #{build_libs_dir}")
        :ok

      files ->
        Enum.each(files, fn src_path ->
          dest_path = src_path |> Path.basename() |> then(&Path.join(avm_deps_dir, &1))
          File.cp!(src_path, dest_path)
          IO.puts("  Copied #{Path.basename(src_path)}")
        end)

        IO.puts("✓ Copied #{length(files)} AVM libraries to #{avm_deps_dir}")
        :ok
    end
  end

  defp build_atomvm(atomvm_path, chip, idf_path, idf_version, use_docker, clean) do

    build_dir = Path.join([atomvm_path, "src", "platforms", "esp32", "build"])
    platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])

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
