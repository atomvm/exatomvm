defmodule Mix.Tasks.Atomvm.Esp32.Install do
  @moduledoc """
  Mix task for erasing flash and installing AtomVM to connected device.

  By default, downloads and installs the latest AtomVM release from GitHub.
  Optionally, can install a specific release using the --version option, or
  a published image by name or a custom-built image by path using the
  --image option.

  **WARNING:** This task erases the current flash before installing, unless
  --update is given.

  ## Options

    * `--image` - Path to a custom AtomVM .img file or .zip bundle, or the name of a
      published image such as `AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7`
      (cannot be combined with `--version`)
    * `--version` - AtomVM release tag to install, including prereleases (cannot be combined with `--image`)
    * `--baud` - Baud rate for flashing (default: 921600, use 115200 for slower devices)
    * `--repo` - A GitHub repository of custom builds, `OWNER/REPO` or its URL, as a further
      source of images: alone, its latest release is installed; with `--version` one of its
      releases; with `--image` one of its images by name, whatever the name; with
      `--list-images` its builds are listed too. Its images are cached under
      `firmware_images/OWNER-REPO/`
    * `--update` - Update an existing AtomVM installation instead of erasing the flash: only
      the virtual machine and its boot library are written, the bootloader, the partition
      table, NVS (Wi-Fi settings and the like) and the application in `main.avm` are kept.
      Refused when the board runs no AtomVM, when its `factory` or `boot.avm` partition
      differs from the image's, or when its bootloader comes from a newer ESP-IDF than the
      image
    * `--list-images` - List the installable images instead: the latest stable release, newer
      prereleases, the nightly builds of atomvm-esp32-firmware-factory (with extra components
      and features such as PSRAM support), and the images on disk. With a connected board, only
      the images for its chip are listed.
    * `--chip` - With `--list-images`, list the images for this chip, e.g. `esp32s3`, or `all`

  ## Examples

      # See which images can be installed
      mix atomvm.esp32.install --list-images

      # Install latest release from GitHub (erases flash)
      mix atomvm.esp32.install

      # Install custom-built image (erases flash)
      mix atomvm.esp32.install --image ./_build/atomvm_images/atomvm-esp32s3-elixir.img

      # Install a published image by name, here a nightly build (erases flash)
      mix atomvm.esp32.install --image AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7

      # Install a specific release, including prereleases (erases flash)
      mix atomvm.esp32.install --version v0.7.0-alpha.1

      # Install a custom build published by another repository (erases flash)
      mix atomvm.esp32.install --repo acme/atomvm-builds --image esp32s3-kiosk.img

      # Update the AtomVM already on the board to the latest release, keeping
      # NVS and the application
      mix atomvm.esp32.install --update

      # Install with custom baud rate
      mix atomvm.esp32.install --baud 115200

  Downloaded images are kept in `firmware_images/` at the root of the project.

  After install, your project can be flashed with:
      mix atomvm.esp32.flash
  """
  use Mix.Task

  @shortdoc "Install AtomVM to ESP32 device"

  # Req is an optional dependency, see check_req_dependency/0.
  @compile {:no_warn_undefined, Req}

  alias ExAtomVM.Esp32FirmwareImages
  alias ExAtomVM.EsptoolHelper

  @usage "mix atomvm.esp32.install [--version TAG | --image FILE_OR_NAME] [--repo OWNER/REPO] " <>
           "[--update] [--baud RATE], or mix atomvm.esp32.install --list-images [--chip CHIP] " <>
           "[--repo OWNER/REPO]"

  @partition_table_offset 0x8000
  @partition_table_size 0xC00
  @bootloader_header_size 0x70
  @update_dir "_build/atomvm_update"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          image: :string,
          version: :string,
          baud: :string,
          repo: :string,
          update: :boolean,
          list_images: :boolean,
          chip: :string
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("Usage: #{@usage}")

    baud = Keyword.get(opts, :baud, "921600")
    image = Keyword.get(opts, :image)
    version = Keyword.get(opts, :version)
    source = repo_source(Keyword.get(opts, :repo))
    mode = if opts[:update], do: :update, else: :install

    cond do
      opts[:list_images] && (image || version || opts[:update]) ->
        Mix.raise("--list-images cannot be combined with --image, --version or --update")

      opts[:list_images] ->
        list_images(opts[:chip], source)

      opts[:chip] ->
        Mix.raise("--chip only applies to --list-images")

      image && version ->
        Mix.raise("--image and --version cannot be used together")

      image ->
        case Esp32FirmwareImages.classify_image_arg(image, source != nil) do
          {:path, path} ->
            install({:path, path}, baud, source, mode)

          {:name, image} ->
            install({:name, image}, baud, source, mode)

          :error ->
            Mix.raise(
              "--image must be an image file or the name of a published image: #{image}; " <>
                "list them with --list-images"
            )
        end

      true ->
        install({:release, version}, baud, source, mode)
    end
  end

  defp repo_source(nil), do: nil

  defp repo_source(arg) do
    case Esp32FirmwareImages.parse_repo_arg(arg) do
      {:ok, repo} -> {:repo, repo}
      :error -> Mix.raise("--repo must be a GitHub repository, OWNER/REPO or its URL: #{arg}")
    end
  end

  defp list_images(chip, source) do
    with {:error, :req_not_available, message} <- check_req_dependency(), do: fail(message)
    {:ok, _} = Application.ensure_all_started(:req)
    {filter, header} = list_filter(chip)
    sources = [:atomvm, :factory] ++ List.wrap(source)

    {sections, header} =
      case Esp32FirmwareImages.fetch_listing(sources) do
        {:ok, sections} ->
          {sections, header}

        {:error, reason} ->
          {[],
           header ++
             [
               "Warning: " <> Esp32FirmwareImages.format_error(reason),
               "Only local images are listed."
             ]}
      end

    sections = sections ++ [Esp32FirmwareImages.local_section()]
    IO.puts(Esp32FirmwareImages.render_list(sections, filter: filter, header: header))
  end

  defp list_filter("all"), do: {nil, []}
  defp list_filter(chip) when is_binary(chip), do: {[chip], []}

  defp list_filter(nil) do
    case EsptoolHelper.setup() do
      :ok ->
        case EsptoolHelper.connected_devices() do
          [] ->
            {nil, ["No ESP32 device found, listing every image."]}

          devices ->
            chips =
              devices
              |> Enum.map(&Esp32FirmwareImages.chip_token(&1["chip_family_name"]))
              |> Enum.uniq()

            {chips, Enum.map(devices, &connected_line/1)}
        end

      {:error, :pythonx_not_available, _message} ->
        {nil, ["Pythonx is not available, listing every image."]}
    end
  end

  defp connected_line(device) do
    installed = EsptoolHelper.installed_version(device) || "no AtomVM"
    "Connected: #{device["chip_family_name"]} on #{device["port"]}, installed: #{installed}"
  end

  defp install(selector, baud, source, mode) do
    with :ok <- check_dependencies(selector),
         :ok <- EsptoolHelper.setup(),
         device <- EsptoolHelper.select_device(),
         chip = Esp32FirmwareImages.chip_token(device["chip_family_name"]),
         {:ok, image} <- resolve_image(selector, chip, source),
         :ok <- check_chip(image, chip, device),
         {:ok, offset} <- Esp32FirmwareImages.flash_offset_for(image, chip),
         {:ok, plan} <- plan(mode, device, image, offset),
         :ok <- confirm(mode, device, image, chip, offset, plan),
         {:erase, true} <- {:erase, erase(mode, device)},
         {:flash, true} <- {:flash, write(mode, device, image, offset, baud, plan)} do
      banner(mode, device)
    else
      {:error, :req_not_available, message} ->
        fail(message)

      {:error, :pythonx_not_available, message} ->
        fail(message)

      {:error, reason} when is_binary(reason) ->
        fail(reason)

      {:error, reason} ->
        fail(Esp32FirmwareImages.format_error(reason))

      {:erase, false} ->
        fail("erasing the flash failed")

      {:flash, false} ->
        fail("flashing AtomVM failed")
    end
  end

  defp fail(message) do
    IO.puts("\nError: #{message}")
    exit({:shutdown, 1})
  end

  defp check_dependencies({:path, _path}), do: :ok
  defp check_dependencies(_selector), do: check_req_dependency()

  defp resolve_image({:release, version}, chip, source) do
    {:ok, _} = Application.ensure_all_started(:req)

    with {:ok, image} <- release_image(chip, version, source || :atomvm) do
      if version == nil and source == nil, do: IO.puts("\n" <> latest_release_hint(image.tag))
      cache(image)
    end
  end

  defp resolve_image({:name, image}, _chip, source) do
    {:ok, _} = Application.ensure_all_started(:req)

    with {:ok, image} <- Esp32FirmwareImages.resolve(image, source) do
      cache(image)
    end
  end

  defp resolve_image({:path, path}, _chip, _source) do
    if String.ends_with?(path, ".zip") do
      Esp32FirmwareImages.local_bundle(path)
    else
      {:ok, Esp32FirmwareImages.local_image(path)}
    end
  end

  @doc false
  def latest_release_hint(tag) do
    """
    💡 Installing AtomVM #{tag}, the latest stable release.
       Nightly builds and images with extra components and features (for example
       PSRAM support) are also available: mix atomvm.esp32.install --list-images
    """
  end

  # An AtomVM release image has a fixed name, so a cached copy is used without
  # asking GitHub which assets the release has.
  defp release_image(chip, version, source) do
    cached =
      if source == :atomvm and version,
        do: Esp32FirmwareImages.find_cached("AtomVM-#{chip}-elixir-#{version}"),
        else: []

    case cached do
      [image | _older] ->
        {:ok, image}

      [] ->
        with {:ok, release} <- Esp32FirmwareImages.fetch_release(source, version) do
          release
          |> Esp32FirmwareImages.release_images(source)
          |> Esp32FirmwareImages.select_release_image(release["tag_name"], chip)
        end
    end
  end

  defp cache(image) do
    with {:ok, image, status} <-
           Esp32FirmwareImages.ensure_cached(image, log: &IO.puts("\n" <> &1)) do
      if status == :downloaded, do: print_gitignore_hint()
      {:ok, image}
    end
  end

  defp check_chip(image, chip, device) do
    case Esp32FirmwareImages.compatible?(image, chip) do
      false ->
        {:error,
         {:chip_mismatch, image.file, Esp32FirmwareImages.image_chip(image),
          device["chip_family_name"]}}

      _true_or_unknown ->
        :ok
    end
  end

  defp plan(:install, _device, _image, _offset), do: {:ok, nil}

  defp plan(:update, device, image, offset) do
    port = device["port"]

    with :ok <- if(device["atomvm_installed"], do: :ok, else: {:error, :not_installed}),
         {:ok, parts} <- Esp32FirmwareImages.update_parts(image, offset),
         {:ok, table} <-
           EsptoolHelper.read_flash_with_size(
             port,
             @partition_table_offset,
             @partition_table_size,
             false
           ),
         {:ok, bootloader} <-
           EsptoolHelper.read_flash_with_size(
             port,
             table["bootloader_offset"],
             @bootloader_header_size,
             true
           ),
         %{app: {_, _, app}, lib: {_, _, lib}} = parts,
         :ok <-
           Esp32FirmwareImages.check_update_layout(
             table["data"],
             parts.table,
             byte_size(app),
             byte_size(lib)
           ),
         {:ok, bootloaders} <-
           Esp32FirmwareImages.check_bootloader(bootloader["data"], parts.bootloader) do
      {:ok, %{parts: parts, bootloaders: bootloaders}}
    end
  end

  defp confirm(:install, device, image, chip, offset, _plan) do
    [first | rest] = Esp32FirmwareImages.describe(image, offset)
    warnings = Esp32FirmwareImages.warnings(image, chip)

    ask(
      ["Erase the flash of #{device_line(device)}", "and install #{first}" | rest],
      warnings,
      "Erasing and flashing"
    )
  end

  defp confirm(:update, device, image, chip, _offset, plan) do
    installed = EsptoolHelper.installed_version(device)

    summary =
      Esp32FirmwareImages.update_summary(installed, plan.bootloaders.board, image, plan.parts)

    warnings = Esp32FirmwareImages.warnings(image, chip) ++ List.wrap(plan.bootloaders.warning)
    ask(["Update AtomVM on #{device_line(device)}" | summary], warnings, "Updating")
  end

  defp device_line(device) do
    "#{device["chip_family_name"]} - Port: #{device["port"]} MAC: #{device["mac_address"]}"
  end

  defp ask(lines, warnings, doing) do
    lines = ["" | lines] ++ Enum.map(warnings, &"Warning: #{&1}") ++ ["Continue? [N/y]: "]
    confirmation = IO.gets(Enum.join(lines, "\n"))
    input = if is_binary(confirmation), do: String.trim(confirmation), else: ""

    if input in ["Y", "y"] do
      IO.puts(doing)
      :ok
    else
      IO.puts("Cancelled.")
      exit({:shutdown, 0})
    end
  end

  defp erase(:update, _device), do: true

  defp erase(:install, device) do
    erased = erase_flash(device)
    if erased, do: :timer.sleep(3000)
    erased
  end

  defp write(:install, device, image, offset, baud, _plan) do
    flash_image(device, image, offset, baud)
  end

  defp write(:update, device, _image, _offset, baud, plan) do
    File.mkdir_p!(@update_dir)

    files =
      for {offset, name, data} <- [plan.parts.app, plan.parts.lib] do
        path = Path.join(@update_dir, name)
        File.write!(path, data)
        {offset, path}
      end

    EsptoolHelper.write_flash_parts(device["port"], baud, files)
  end

  defp banner(:install, device) do
    IO.puts("""

      Successfully installed AtomVM on #{device_line(device)}

      Your project can now be flashed with:
        mix atomvm.esp32.flash

    """)
  end

  defp banner(:update, device) do
    IO.puts("""

      Successfully updated AtomVM on #{device_line(device)}

      The application in main.avm was kept; a new one can be flashed with:
        mix atomvm.esp32.flash

    """)
  end

  defp check_req_dependency do
    case Code.ensure_loaded(Req) do
      {:module, _} ->
        :ok

      {:error, _} ->
        {:error, :req_not_available,
         "The 'req' package is not available. Please ensure it is listed in your dependencies.\n{:req, \"~> 0.5.0\", runtime: false}"}
    end
  end

  defp print_gitignore_hint do
    gitignore =
      case File.read(".gitignore") do
        {:ok, text} -> text
        {:error, _reason} -> nil
      end

    case Esp32FirmwareImages.gitignore_hint(gitignore) do
      nil -> :ok
      hint -> IO.puts("\n" <> hint)
    end
  end

  defp erase_flash(device) do
    EsptoolHelper.erase_flash([
      "--port",
      device["port"],
      "--chip",
      "auto",
      "--after",
      "no-reset"
    ])
  end

  defp flash_image(device, image, offset, baud) do
    EsptoolHelper.flash_pythonx([
      "--chip",
      "auto",
      "--port",
      device["port"],
      "--baud",
      baud,
      "write-flash",
      Esp32FirmwareImages.format_hex(offset),
      Esp32FirmwareImages.image_path(image)
    ])
  end
end
