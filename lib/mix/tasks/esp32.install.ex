defmodule Mix.Tasks.Atomvm.Esp32.Install do
  @moduledoc """
  Mix task for erasing flash and installing AtomVM to connected device.

  By default, downloads and installs the latest AtomVM release from GitHub.
  Optionally, can install a specific release using the --version option or a
  custom-built image using the --image option.

  **WARNING:** This task erases the current flash before installing.

  ## Options

    * `--image` - Path to a custom AtomVM .img file (cannot be combined with `--version`)
    * `--version` - AtomVM release tag to install, including prereleases (cannot be combined with `--image`)
    * `--baud` - Baud rate for flashing (default: 921600, use 115200 for slower devices)

  ## Examples

      # Install latest release from GitHub (erases flash)
      mix atomvm.esp32.install

      # Install custom-built image (erases flash)
      mix atomvm.esp32.install --image ./_build/atomvm_images/atomvm-esp32s3-elixir.img

      # Install a specific release, including prereleases (erases flash)
      mix atomvm.esp32.install --version v0.7.0-alpha.1

      # Install with custom baud rate
      mix atomvm.esp32.install --baud 115200

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

      {image_path, nil} ->
        if not File.exists?(image_path) do
          IO.puts("Error: Image file not found: #{image_path}")
          exit({:shutdown, 1})
        end

        install({:image, image_path}, baud)

      {_image_path, _version} ->
        Mix.raise("--image and --version cannot be used together")
    end
  end

  defp install(selector, baud) do
    with :ok <- check_dependencies(selector),
         :ok <- EsptoolHelper.setup(),
         selected_device <- EsptoolHelper.select_device(),
         image_file <- image_file(selector, selected_device),
         :ok <- confirm_erase_and_flash(selected_device, image_file),
         {:erase, true} <- {:erase, erase_flash(selected_device)},
         :timer.sleep(3000),
         {:flash, true} <- {:flash, flash_release(selected_device, image_file, baud)} do
      IO.puts("""

        Successfully installed AtomVM on #{selected_device["chip_family_name"]} Port: #{selected_device["port"]} MAC: #{selected_device["mac_address"]}

        Your project can now be flashed with:
          mix atomvm.esp32.flash

      """)
    else
      {:error, :req_not_available, message} ->
        IO.puts("\nError: #{message}")
        exit({:shutdown, 1})

      {:error, :pythonx_not_available, message} ->
        IO.puts("\nError: #{message}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts("Error: #{reason}")
        exit({:shutdown, 1})

      {:erase, false} ->
        IO.puts("\nError: erasing the flash failed")
        exit({:shutdown, 1})

      {:flash, false} ->
        IO.puts("\nError: flashing AtomVM failed")
        exit({:shutdown, 1})
    end
  end

  # Only a release download needs Req.
  defp check_dependencies({:release, _version}), do: check_req_dependency()
  defp check_dependencies({:image, _path}), do: :ok

  defp image_file({:release, version}, device) do
    get_release(device["chip_family_name"], version)
  end

  defp image_file({:image, path}, _device), do: path

  defp confirm_erase_and_flash(selected_device, release_file) do
    confirmation =
      IO.gets("""

      Are you sure you want to erase the flash of
      #{selected_device["chip_family_name"]} - Port: #{selected_device["port"]} MAC: #{selected_device["mac_address"]}
      And install AtomVM: #{Path.basename(release_file)}
      ? [N/y]:

      """)

    case String.trim(confirmation) do
      input when input in ["Y", "y"] ->
        IO.puts("Erasing and flashing")
        :ok

      _ ->
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
         "\nError: The 'req' package is not available. Please ensure it is listed in your dependencies.\n{:req, \"~> 0.5.0\", runtime: false}"}
    end
  end

  defp get_release(chip_family, version) do
    {:ok, _} = Application.ensure_all_started(:req)
    chip = Esp32FirmwareImages.chip_token(chip_family)

    with {:ok, image} <- release_image(chip, version),
         {:ok, image, status} <-
           Esp32FirmwareImages.ensure_cached(image, log: &IO.puts("\n" <> &1)) do
      if status == :downloaded, do: print_gitignore_hint()
      image.path
    else
      {:error, reason} -> raise Esp32FirmwareImages.format_error(reason)
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

  defp flash_release(device, release_file, baud) do
    flash_offset =
      %{
        "ESP32" => "0x1000",
        "ESP32-S2" => "0x1000",
        "ESP32-S3" => "0x0",
        "ESP32-C2" => "0x0",
        "ESP32-C3" => "0x0",
        "ESP32-C5" => "0x2000",
        "ESP32-C6" => "0x0",
        "ESP32-C61" => "0x0",
        "ESP32-H2" => "0x0",
        "ESP32-P4" => "0x2000"
      }[device["chip_family_name"]] || "0x0"

    tool_args = [
      "--chip",
      "auto",
      "--port",
      device["port"],
      "--baud",
      baud,
      "write-flash",
      flash_offset,
      release_file
    ]

    EsptoolHelper.flash_pythonx(tool_args)
  end
end
