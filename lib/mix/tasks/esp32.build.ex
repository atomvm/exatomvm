defmodule Mix.Tasks.Atomvm.Esp32.Build do
  @moduledoc """
  Mix task for building AtomVM for ESP32 from source.

  Builds AtomVM from a local repository or git URL using ESP-IDF.

  ## Requirements

  **General requirements**
    * Erlang/OTP (25 or later)
    * Elixir (1.16 or later)
    * Git

  **Without Docker:**
    * CMake (3.13 or later)
    * Ninja (preferred) or Make
    * ESP-IDF (v5.5.4 or later recommended)

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
    * `--idf-version` - ESP-IDF version for Docker image (default: v5.5.4)
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

      # Build using Docker (relative paths are expanded automatically)
      mix atomvm.esp32.build --atomvm-path ./_build/atomvm_source/AtomVM/ --use-docker --chip esp32s3

      # Build using Docker with specific IDF version
      mix atomvm.esp32.build --atomvm-path ./_build/atomvm_source/AtomVM/ --use-docker --idf-version v5.5.4 --chip esp32s3

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
  @default_idf_version "v5.5.4"
  @elixir_cmake_arg "-DATOMVM_ELIXIR_SUPPORT=on"

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

    # Use --atomvm-path, --atomvm-url, or default to AtomVM/AtomVM main branch.
    # Expand to an absolute path so Docker bind mounts (`-v <host>:/project`)
    # and any later relative-path math work consistently.
    atomvm_path =
      cond do
        atomvm_path ->
          atomvm_path

        true ->
          ExAtomVM.AtomVMBuilder.clone_or_update_repo(atomvm_url, ref)
      end
      |> Path.expand()

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
         :ok <- check_escript(),
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
            {:ok, src_img} ->
              img = save_image(src_img)
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
    Path.relative_to(path, cwd, force: true)
  end

  defp check_escript do
    case System.find_executable("escript") do
      nil ->
        {:error, "escript not found. Please install Erlang/OTP and ensure escript is on PATH."}

      _ ->
        :ok
    end
  end

  defp save_image(src_img) do
    output_dir = Path.join([File.cwd!(), "_build", "atomvm_images"])
    File.mkdir_p!(output_dir)
    dest_img = Path.join(output_dir, Path.basename(src_img))

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
           ESP-IDF not found in the current environment.

           If ESP-IDF is already installed, activate it in this shell with:

             get_idf

           If the get_idf alias is not configured, source the export script directly:

             . "$HOME/esp/esp-idf/export.sh"

           To install ESP-IDF, follow Espressif's setup guide:

           https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/

           Alternatively, use --use-docker to build with Espressif's ESP-IDF Docker image.
           """}

        idf_path_found ->
          IO.puts("Found ESP-IDF: #{idf_path_found}")
          :ok
      end
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
      ExAtomVM.AtomVMBuilder.clean_dir(build_dir)
    end

    IO.puts("Configuring build for #{chip}...")

    {_output, status} =
      run_idf_command(
        use_docker,
        idf_version,
        atomvm_path,
        platform_dir,
        idf_path,
        idf_set_target_args(chip)
      )

    case status do
      0 ->
        IO.puts("Building AtomVM... (this may take several minutes)")

        {_output, build_status} =
          run_idf_command(
            use_docker,
            idf_version,
            atomvm_path,
            platform_dir,
            idf_path,
            idf_build_args()
          )

        case build_status do
          0 ->
            copy_dependencies_lock(platform_dir)

            create_flashable_image(
              Path.expand(atomvm_path),
              Path.expand(build_dir),
              chip,
              use_docker
            )

          _status ->
            {:error, "Build failed"}
        end

      _status ->
        {:error, "Failed to set target chip"}
    end
  end

  defp idf_set_target_args(chip) do
    [@elixir_cmake_arg, "set-target", chip]
  end

  defp idf_build_args do
    [@elixir_cmake_arg, "build"]
  end

  defp run_idf_command(true, idf_version, atomvm_path, platform_dir, _idf_path, idf_args) do
    run_idf_docker(idf_version, atomvm_path, platform_dir, idf_args)
  end

  defp run_idf_command(false, _idf_version, _atomvm_path, platform_dir, idf_path, idf_args) do
    System.cmd(idf_path, idf_args,
      cd: platform_dir,
      stderr_to_stdout: true,
      into: IO.stream(:stdio, :line)
    )
  end

  defp copy_dependencies_lock(platform_dir) do
    repo_dependencies_lock = Path.join(platform_dir, "dependencies.lock")

    if File.exists?(repo_dependencies_lock) do
      dest_path = Path.join(File.cwd!(), "dependencies.lock")

      if not File.exists?(dest_path) or
           File.read!(dest_path) != File.read!(repo_dependencies_lock) do
        IO.puts("Updating project dependencies.lock from ESP-IDF component manager...")
        File.cp!(repo_dependencies_lock, dest_path)
      end
    end
  end

  defp create_flashable_image(atomvm_path, build_dir, chip, use_docker) do
    mkimage_erl = Path.join(build_dir, "mkimage.erl")
    mkimage_config = Path.join(build_dir, "mkimage.config")
    output_img = Path.join(build_dir, "atomvm-#{chip}-elixir.img")

    cond do
      not File.exists?(mkimage_erl) ->
        {:error, "mkimage.erl not found in #{build_dir}"}

      not File.exists?(mkimage_config) ->
        {:error, "mkimage.config not found in #{build_dir}"}

      stock_esp32boot_configured?(mkimage_config) ->
        {:error,
         "mkimage.config still points at stock esp32boot.avm. " <>
           "The ESP32 build was not configured with AtomVM Elixir support; " <>
           "retry with --clean, and ensure the AtomVM ref honours -DATOMVM_ELIXIR_SUPPORT=on " <>
           "(older AtomVM revisions predate this CMake option)."}

      true ->
        IO.puts("Creating flashable image...")
        run_mkimage(atomvm_path, build_dir, mkimage_erl, mkimage_config, output_img, use_docker)
    end
  end

  defp stock_esp32boot_configured?(mkimage_config) do
    mkimage_config
    |> File.read!()
    |> String.contains?("esp32boot/esp32boot.avm")
  end

  defp run_mkimage(atomvm_path, build_dir, mkimage_erl, mkimage_config, output_img, use_docker) do
    case System.find_executable("escript") do
      nil ->
        {:error, "escript not found. Please install Erlang/OTP and ensure escript is on PATH."}

      escript ->
        # Only Docker-generated configs reference container `/project` paths and
        # need localizing; local builds already contain valid host paths.
        local_config =
          if use_docker do
            local_mkimage_config(atomvm_path, build_dir, mkimage_config)
          else
            mkimage_config
          end

        {_output, status} =
          System.cmd(
            escript,
            [mkimage_erl, "--config", local_config, "--out", output_img],
            cd: build_dir,
            stderr_to_stdout: true,
            into: IO.stream(:stdio, :line)
          )

        case status do
          0 -> verify_output_image(output_img)
          _ -> {:error, "Failed to create image"}
        end
    end
  end

  defp verify_output_image(output_img) do
    case File.stat(output_img) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
        {:ok, output_img}

      {:ok, _stat} ->
        {:error, "mkimage completed but produced no valid image at #{output_img}"}

      {:error, reason} ->
        {:error,
         "mkimage completed but did not create #{output_img}: #{:file.format_error(reason)}"}
    end
  end

  defp local_mkimage_config(atomvm_path, build_dir, mkimage_config) do
    content = File.read!(mkimage_config)
    # The host path is inserted inside an Erlang double-quoted string, so escape
    # any `\` and `"` that are legal in POSIX paths but special in Erlang strings.
    replacement = escape_erlang_string_content(atomvm_path)
    # Only rewrite "/project" when it appears as a path prefix inside a quoted
    # string (i.e. followed by `/` or a closing quote), to avoid clobbering
    # unrelated tokens like "/project_backup/..." or comments.
    # Use the function form so backslashes / `\N` sequences in the replacement
    # are not interpreted as replacement escapes / backrefs by Regex.replace/3.
    local_content =
      Regex.replace(~r{(?<=")/project(?=/|")}, content, fn _ -> replacement end)

    if local_content == content do
      mkimage_config
    else
      local_config = Path.join(build_dir, "mkimage.local.config")
      File.write!(local_config, local_content)
      local_config
    end
  end

  defp escape_erlang_string_content(path) do
    path
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
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
