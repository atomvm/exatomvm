defmodule Mix.Tasks.Atomvm.Esp32.Install do
  @moduledoc """
  Mix task for erasing flash and installing AtomVM to connected device.

  By default, downloads and installs the latest AtomVM release from GitHub.
  Optionally, can install a specific release using the --version option, or
  a published image by name or a custom-built image by path using the
  --image option.

  **WARNING:** This task erases the current flash before installing.

  ## Options

    * `--image` - Path to a custom AtomVM .img file or .zip bundle, or the name of a
      published image such as `AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7`
      (cannot be combined with `--version`)
    * `--version` - AtomVM release tag to install, including prereleases (cannot be combined with `--image`)
    * `--baud` - Baud rate for flashing (default: 921600, use 115200 for slower devices)

  ## Examples

      # Install latest release from GitHub (erases flash)
      mix atomvm.esp32.install

      # Install custom-built image (erases flash)
      mix atomvm.esp32.install --image ./_build/atomvm_images/atomvm-esp32s3-elixir.img

      # Install a published image by name, here a nightly build (erases flash)
      mix atomvm.esp32.install --image AtomVM-esp32s3-atomgl-ipv6-libsodium-psram-nightly-0.7

      # Install a specific release, including prereleases (erases flash)
      mix atomvm.esp32.install --version v0.7.0-alpha.1

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

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args, strict: [image: :string, version: :string, baud: :string])

    baud = Keyword.get(opts, :baud, "921600")

    case {Keyword.get(opts, :image), Keyword.get(opts, :version)} do
      {nil, version} ->
        install({:release, version}, baud)

      {image, nil} ->
        case Esp32FirmwareImages.classify_image_arg(image) do
          {:path, path} ->
            install({:path, path}, baud)

          {:name, image} ->
            install({:name, image}, baud)

          :error ->
            Mix.raise("--image must be an image file or the name of a published image: #{image}")
        end

      {_image, _version} ->
        Mix.raise("--image and --version cannot be used together")
    end
  end

  defp install(selector, baud) do
    with :ok <- check_dependencies(selector),
         :ok <- EsptoolHelper.setup(),
         device <- EsptoolHelper.select_device(),
         chip = Esp32FirmwareImages.chip_token(device["chip_family_name"]),
         {:ok, image} <- resolve_image(selector, chip),
         :ok <- check_chip(image, chip, device),
         {:ok, offset} <- Esp32FirmwareImages.flash_offset_for(image, chip),
         :ok <- confirm_erase_and_flash(device, image, chip, offset),
         {:erase, true} <- {:erase, erase_flash(device)},
         :timer.sleep(3000),
         {:flash, true} <- {:flash, flash_image(device, image, offset, baud)} do
      IO.puts("""

        Successfully installed AtomVM on #{device["chip_family_name"]} Port: #{device["port"]} MAC: #{device["mac_address"]}

        Your project can now be flashed with:
          mix atomvm.esp32.flash

      """)
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

  defp resolve_image({:release, version}, chip) do
    {:ok, _} = Application.ensure_all_started(:req)

    with {:ok, image} <- release_image(chip, version) do
      cache(image)
    end
  end

  defp resolve_image({:name, image}, _chip) do
    {:ok, _} = Application.ensure_all_started(:req)

    with {:ok, image} <- Esp32FirmwareImages.resolve(image) do
      cache(image)
    end
  end

  defp resolve_image({:path, path}, _chip) do
    if String.ends_with?(path, ".zip") do
      Esp32FirmwareImages.local_bundle(path)
    else
      {:ok, Esp32FirmwareImages.local_image(path)}
    end
  end

  # A release image has a fixed name, so a cached copy is used without asking
  # GitHub which assets the release has.
  defp release_image(chip, version) do
    case version && Esp32FirmwareImages.find_cached("AtomVM-#{chip}-elixir-#{version}") do
      [image | _] ->
        {:ok, image}

      _ ->
        with {:ok, release} <- Esp32FirmwareImages.fetch_release(:atomvm, version) do
          release
          |> Esp32FirmwareImages.release_images()
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

  defp confirm_erase_and_flash(device, image, chip, offset) do
    [first | rest] = Esp32FirmwareImages.describe(image, offset)
    warnings = Enum.map(Esp32FirmwareImages.warnings(image, chip), &"Warning: #{&1}")

    lines =
      [
        "",
        "Erase the flash of #{device["chip_family_name"]} - Port: #{device["port"]} MAC: #{device["mac_address"]}",
        "and install #{first}" | rest
      ] ++ warnings ++ ["Continue? [N/y]: "]

    confirmation = IO.gets(Enum.join(lines, "\n"))
    input = if is_binary(confirmation), do: String.trim(confirmation), else: ""

    if input in ["Y", "y"] do
      IO.puts("Erasing and flashing")
      :ok
    else
      IO.puts("Install cancelled.")
      exit({:shutdown, 0})
    end
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
