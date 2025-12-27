defmodule ExAtomVM.AtomVMBuilder do
  @moduledoc """
  Shared utilities for building AtomVM from source.

  Provides common functionality used by platform-specific build tasks (ESP32, STM32, Pico, etc.):

    * Git repository management (clone, update, checkout)
    * Generic Unix build (PackBEAM, atomvmlib, exavmlib, esp32boot)
    * AVM library copying to `avm_deps/`

  Platform-specific build tasks should delegate to this module for shared operations.
  """

  @default_atomvm_url "https://github.com/atomvm/AtomVM"

  @doc """
  Clone or update an AtomVM repository at the given URL and ref.

  Returns the path to the local repository.
  """
  def clone_or_update_repo(url \\ @default_atomvm_url, ref) do
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

  @doc """
  Build generic Unix tools and libraries from an AtomVM source tree.

  Builds PackBEAM, elixir_esp32boot, exavmlib, and atomvmlib using cmake + ninja/make.

  ## Options

    * `atomvm_path` - Path to AtomVM source repository
    * `mbedtls_prefix` - Optional path to custom MbedTLS installation
    * `clean` - Whether to clean the build directory first
  """
  def build_generic_unix(atomvm_path, mbedtls_prefix \\ nil, clean \\ false) do
    build_dir = Path.join(atomvm_path, "build")

    if clean and File.dir?(build_dir) do
      IO.puts("Cleaning generic Unix build directory...")
      File.rm_rf!(build_dir)
    end

    packbeam_path = Path.join([build_dir, "tools", "packbeam", "PackBEAM"])
    esp32boot_path = Path.join([build_dir, "libs", "esp32boot", "elixir_esp32boot.avm"])

    if File.exists?(packbeam_path) and File.exists?(esp32boot_path) do
      IO.puts("Generic Unix build tools and elixir_esp32boot already exist, skipping...")
      :ok
    else
      IO.puts("Building generic Unix tools and elixir_esp32boot (required for build)...")
      File.mkdir_p!(build_dir)

      {build_tool, cmake_generator} =
        case System.find_executable("ninja") do
          nil ->
            IO.puts("Ninja not found, using Make as build system")
            {"make", []}

          _ninja_path ->
            IO.puts("Using Ninja as build system")
            {"ninja", ["-GNinja"]}
        end

      mbedtls_args =
        if mbedtls_prefix do
          IO.puts("Using custom MbedTLS from: #{mbedtls_prefix}")
          ["-DCMAKE_PREFIX_PATH=#{mbedtls_prefix}"]
        else
          []
        end

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

  @doc """
  Copy built AVM libraries from the AtomVM build tree into the project's `avm_deps/` directory.

  This is needed for platforms (like STM32, Pico) where the AVM libraries must be bundled
  into the application `.avm` file. ESP32 does NOT need this — its libraries are baked into
  the firmware image and flashed to a separate partition.
  """
  def copy_avm_libraries(atomvm_path) do
    avm_deps_dir = File.cwd!() |> Path.join("avm_deps")

    if File.dir?(avm_deps_dir) do
      IO.puts("Removing existing avm_deps folder...")
      File.rm_rf!(avm_deps_dir)
    end

    IO.puts("Creating avm_deps folder and copying libraries...")
    File.mkdir_p!(avm_deps_dir)

    build_libs_dir = atomvm_path |> Path.join("build") |> Path.join("libs")
    avm_files = build_libs_dir |> Path.join("**/*.avm") |> Path.wildcard()

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

  # --- Private git helpers ---

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
    System.cmd("git", ["reset", "--hard"],
      cd: repo_path,
      stderr_to_stdout: true
    )

    case parse_pr_ref(ref) do
      {:pr, pr_number} ->
        fetch_and_checkout_pr(repo_path, pr_number)

      :not_pr ->
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
  end

  defp parse_pr_ref(ref) do
    cond do
      match = Regex.run(~r/^pull\/(\d+)\/head$/, ref) ->
        {:pr, Enum.at(match, 1)}

      match = Regex.run(~r/^pr\/(\d+)$/, ref) ->
        {:pr, Enum.at(match, 1)}

      true ->
        :not_pr
    end
  end

  defp fetch_and_checkout_pr(repo_path, pr_number) do
    branch = "pr-#{pr_number}"

    IO.puts("Fetching PR ##{pr_number}...")

    {output, status} =
      System.cmd("git", ["fetch", "origin", "pull/#{pr_number}/head"],
        cd: repo_path,
        stderr_to_stdout: true
      )

    case status do
      0 ->
        IO.puts(output)

        {output, status} =
          System.cmd("git", ["checkout", "-B", branch, "FETCH_HEAD"],
            cd: repo_path,
            stderr_to_stdout: true
          )

        case status do
          0 ->
            IO.puts(output)
            IO.puts("Checked out PR ##{pr_number}")
            repo_path

          _ ->
            IO.puts("Error checking out PR branch:\n#{output}")
            exit({:shutdown, 1})
        end

      _ ->
        IO.puts("Error fetching PR ##{pr_number}:\n#{output}")
        exit({:shutdown, 1})
    end
  end

  defp pull_if_branch(repo_path, ref) do
    {_output, status} =
      System.cmd("git", ["symbolic-ref", "-q", "HEAD"],
        cd: repo_path,
        stderr_to_stdout: true
      )

    if status == 0 do
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
      IO.puts("Checked out tag or commit (detached HEAD)")
      repo_path
    end
  end
end
