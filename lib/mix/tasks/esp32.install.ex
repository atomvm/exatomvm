defmodule Mix.Tasks.Atomvm.Esp32.Install do
  @moduledoc """
  Mix task for erasing flash and installing the latest AtomVM release to connected device.

  Takes an optional --baud option to set the baud rate of the flashing.
  Defaults to 921600, use 115200 for slower devices.

  After install, your project can be flashed with:
      mix atomvm.esp32.flash
  """
  use Mix.Task

  @shortdoc "Install latest AtomVM release on ESP32"

  alias ExAtomVM.EsptoolHelper

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [baud: :string])
    baud = Keyword.get(opts, :baud, "921600")

    with :ok <- check_req_dependency(),
         :ok <- EsptoolHelper.setup(),
         selected_device <- EsptoolHelper.select_device(),
         release_file <- get_latest_release(selected_device["chip_family_name"]),
         :ok <- confirm_erase_and_flash(selected_device, release_file),
         true <-
           EsptoolHelper.erase_flash([
             "--port",
             selected_device["port"],
             "--chip",
             "auto",
             "--after",
             "no-reset"
           ]),
         :timer.sleep(3000),
         true <- flash_release(selected_device, release_file, baud) do
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
    end
  end

  defp confirm_erase_and_flash(selected_device, release_file) do
    confirmation =
      IO.gets("""

      Are you sure you want to erase the flash of
      #{selected_device["chip_family_name"]} - Port: #{selected_device["port"]} MAC: #{selected_device["mac_address"]}
      And install AtomVM: #{release_file}
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

  defp get_latest_release(chip_family) do
    cache_dir =
      if Code.ensure_loaded?(Mix.Project) do
        Path.join(Path.dirname(Mix.Project.build_path()), "atomvm_binaries")
      else
        Path.expand("_build/atomvm_binaries")
      end

    File.mkdir_p!(cache_dir)

    {:ok, _} = Application.ensure_all_started(:req)

    with {:ok, response} <- Req.get("https://api.github.com/repos/atomvm/atomvm/releases/latest"),
         %{status: 200, body: body} <- response,
         assets <- body["assets"] || [],
         asset when not is_nil(asset) <- Enum.find(assets, &matches_chip_family?(&1, chip_family)) do
      cached_file = Path.join(cache_dir, asset["name"])

      if !File.exists?(cached_file) do
        IO.puts("\nDownloading #{asset["name"]}, may take a while...")
        {:ok, _response} = Req.get(asset["browser_download_url"], into: File.stream!(cached_file))
        cached_file
      else
        IO.puts("\nUsing cached #{asset["name"]}")
        cached_file
      end
    else
      {:error, reason} ->
        raise "Failed to fetch release: #{inspect(reason)}"

      %{status: status} ->
        raise "GitHub API returned status #{status}"

      nil ->
        raise "No matching release found for #{chip_family}"
    end
  end

  defp matches_chip_family?(%{"name" => name}, chip_family) do
    name = String.downcase(name)

    chip_family =
      String.downcase(chip_family)
      |> String.replace("-", "")
      |> String.replace(" ", "")

    String.contains?(name, [chip_family]) && String.contains?(name, ["elixir"]) &&
      String.ends_with?(name, ".img")
  end

  defp flash_release(device, release_file, baud) do
    flash_offset =
      %{
        "ESP32" => "0x1000",
        "ESP32-S2" => "0x1000",
        "ESP32-S3" => "0x0",
        "ESP32-C2" => "0x0",
        "ESP32-C3" => "0x0",
        "ESP32-C6" => "0x0",
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
