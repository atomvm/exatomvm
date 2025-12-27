defmodule Mix.Tasks.Atomvm.Esp32.Build do
  @moduledoc """
  Mix task for building AtomVM for ESP32 from source.

  Builds AtomVM from a local repository or git URL using ESP-IDF.

  ## Options

    * `--atomvm-path` - Path to local AtomVM repository (required if --atomvm-url not provided)
    * `--atomvm-url` - Git URL to clone AtomVM from (optional, overrides path)
    * `--branch` - Git branch to checkout (default: main)
    * `--chip` - Target chip (default: esp32s3, options: esp32, esp32s2, esp32s3, esp32c2, esp32c3, esp32c6, esp32h2, esp32p4)
    * `--clean` - Clean build directory before building

  ## Examples

      # Build from local repository
      mix atomvm.esp32.build --atomvm-path /path/to/AtomVM

      # Build from git URL
      mix atomvm.esp32.build --atomvm-url https://github.com/atomvm/AtomVM --branch main

      # Build for specific chip with clean build
      mix atomvm.esp32.build --atomvm-path /path/to/AtomVM --chip esp32s3 --clean

  """
  use Mix.Task

  @shortdoc "Build AtomVM for ESP32 from source"

  @default_chip "esp32s3"
  @default_branch "main"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          atomvm_path: :string,
          atomvm_url: :string,
          branch: :string,
          chip: :string,
          clean: :boolean
        ]
      )

    atomvm_url = Keyword.get(opts, :atomvm_url)
    atomvm_path = Keyword.get(opts, :atomvm_path)
    branch = Keyword.get(opts, :branch, @default_branch)
    chip = Keyword.get(opts, :chip, @default_chip)
    clean = Keyword.get(opts, :clean, false)

    # Require either --atomvm-path or --atomvm-url
    atomvm_path =
      cond do
        atomvm_url ->
          clone_or_update_repo(atomvm_url, branch)

        atomvm_path ->
          atomvm_path

        true ->
          IO.puts("""
          Error: Either --atomvm-path or --atomvm-url must be provided

          Examples:
            mix atomvm.esp32.build --atomvm-path /path/to/AtomVM
            mix atomvm.esp32.build --atomvm-url https://github.com/atomvm/AtomVM

          """)

          exit({:shutdown, 1})
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

    with :ok <- check_esp_idf(),
         :ok <- build_generic_unix(atomvm_path),
         :ok <- build_atomvm(atomvm_path, chip, clean) do
      build_dir = Path.join([atomvm_path, "src", "platforms", "esp32", "build"])
      atomvm_img = Path.join([build_dir, "atomvm-#{chip}.img"])

      if File.exists?(atomvm_img) do
        IO.puts("""

        ✅ Successfully built AtomVM for #{chip}

        Build directory: #{build_dir}

        Flashable image: #{atomvm_img}

        To flash to your device, run:
          mix atomvm.esp32.build.flash --image #{atomvm_img}

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

  defp clone_or_update_repo(url, branch) do
    cache_dir =
      if Code.ensure_loaded?(Mix.Project) do
        Path.join(Path.dirname(Mix.Project.build_path()), "atomvm_source")
      else
        Path.expand("_build/atomvm_source")
      end

    repo_name = url |> Path.basename() |> String.replace(".git", "")
    repo_path = Path.join(cache_dir, repo_name)

    if File.dir?(Path.join(repo_path, ".git")) do
      IO.puts("Updating existing repository at #{repo_path}")

      {output, status} =
        System.cmd("git", ["pull", "origin", branch],
          cd: repo_path,
          stderr_to_stdout: true
        )

      case status do
        0 ->
          IO.puts(output)
          repo_path

        _ ->
          IO.puts("Error updating repository:\n#{output}")
          exit({:shutdown, 1})
      end
    else
      IO.puts("Cloning #{url} (branch: #{branch})")
      File.mkdir_p!(cache_dir)

      {output, status} =
        System.cmd("git", ["clone", "--branch", branch, url, repo_path],
          stderr_to_stdout: true
        )

      case status do
        0 ->
          IO.puts(output)
          repo_path

        _ ->
          IO.puts("Error cloning repository:\n#{output}")
          exit({:shutdown, 1})
      end
    end
  end

  defp check_esp_idf do
    case System.find_executable("idf.py") do
      nil ->
        {:error,
         """
         ESP-IDF not found. Please install and set up ESP-IDF:

         https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/
         """}

      idf_path ->
        IO.puts("Found ESP-IDF: #{idf_path}")
        :ok
    end
  end

  defp build_generic_unix(atomvm_path) do
    build_dir = Path.join(atomvm_path, "build")

    # Check if tools and esp32boot already exist
    packbeam_path = Path.join([build_dir, "tools", "packbeam", "PackBEAM"])
    esp32boot_path = Path.join([build_dir, "libs", "esp32boot", "esp32boot.avm"])

    if File.exists?(packbeam_path) and File.exists?(esp32boot_path) do
      IO.puts("Generic Unix build tools and esp32boot already exist, skipping...")
      :ok
    else
      IO.puts("Building generic Unix tools and esp32boot (required for ESP32 build)...")
      File.mkdir_p!(build_dir)

      # Run cmake
      {_output, status} =
        System.cmd("cmake", ["..", "-DCMAKE_BUILD_TYPE=Release"],
          cd: build_dir,
          stderr_to_stdout: true,
          into: IO.stream(:stdio, :line)
        )

      case status do
        0 ->
          IO.puts("Building tools and esp32boot...")

          {_output, status} =
            System.cmd("make", ["PackBEAM", "esp32boot", "exavmlib", "atomvmlib"],
              cd: build_dir,
              stderr_to_stdout: true,
              into: IO.stream(:stdio, :line)
            )

          case status do
            0 ->
              IO.puts("Generic Unix tools and esp32boot built successfully")
              :ok

            _ ->
              {:error, "Failed to build generic Unix tools"}
          end

        _ ->
          {:error, "Failed to configure generic Unix build"}
      end
    end
  end

  defp build_atomvm(atomvm_path, chip, clean) do
    build_dir = Path.join([atomvm_path, "src", "platforms", "esp32", "build"])
    platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])

    if clean and File.dir?(build_dir) do
      IO.puts("Cleaning build directory...")
      File.rm_rf!(build_dir)
    end

    IO.puts("Configuring build for #{chip}...")

    # Set target chip
    {_output, status} =
      System.cmd("idf.py", ["set-target", chip],
        cd: platform_dir,
        stderr_to_stdout: true,
        into: IO.stream(:stdio, :line)
      )

    case status do
      0 ->
        IO.puts("Building AtomVM... (this may take several minutes)")

        {_output, status} =
          System.cmd("idf.py", ["build"],
            cd: platform_dir,
            stderr_to_stdout: true,
            into: IO.stream(:stdio, :line)
          )

        case status do
          0 ->
            IO.puts("Creating flashable image...")

            mkimage_script = Path.join([build_dir, "mkimage.sh"])

            {_output, status} =
              System.cmd("sh", [mkimage_script],
                cd: build_dir,
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
end
