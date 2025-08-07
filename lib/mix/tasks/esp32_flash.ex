defmodule Mix.Tasks.Atomvm.Esp32.Flash do
  use Mix.Task

  @shortdoc "Flash the application to an ESP32 micro-controller"

  @moduledoc """
  Flashes the application to an ESP32 micro-controller.

  > #### Important {: .warning}
  >
  > Before running this task, you must flash the AtomVM virtual machine to the target device.
  >
  > This tasks depends on `esptool` and can be installed using package managers:
  >  - linux (debian): apt install esptool
  >  - macos: brew install esptool
  >  - or follow these [installation instructions](https://docs.espressif.com/projects/esptool/en/latest/esp32/installation.html#installation) when not available through a package manager.

  ## Usage example

  Within your AtomVM mix project run

  `
  $ mix atomvm.esp32.flash
  `

  Or with optional flags (which will override the config in mix.exs)

  `
  $ mix atomvm.esp32.flash --port /dev/tty.usbserial-0001
  `

  Or detect the port automatically with

  `
  $ mix atomvm.esp32.flash --port auto
  `

  ## Configuration

  ExAtomVM can be configured from the mix.ex file and supports the following settings for the
  `atomvm.esp32.flash` task.

    * `:flash_offset` - The start address of the flash to write the application to in hexademical format,
      defaults to `0x250000`.

    * `:chip` - Chip type, defaults to `auto`.

    * `:port` - The port to which device is connected on the host computer, defaults to `/dev/ttyUSB0`.

    * `:baud` - The BAUD rate used when flashing to device, defaults to `115200`.

  ## Command line options

  Properties in the mix.exs file may be over-ridden on the command line using long-style flags (prefixed by --) by the same name
  as the [supported properties](#module-configuration)

  For example, you can use the `--port` option to specify or override the port property.
  """

  alias Mix.Project
  alias Mix.Tasks.Atomvm.Packbeam

  @esp_tool_path "/components/esptool_py/esptool/esptool.py"

  def run(args) do
    config = Project.config()

    with {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:args, {:ok, options}} <- {:args, parse_args(args)},
         {:pack, {:ok, _}} <- {:pack, Packbeam.run(args)},
         idf_path <- System.get_env("IDF_PATH", <<"">>) do
      chip = Map.get(options, :chip, Keyword.get(avm_config, :chip, "auto"))
      port = Map.get(options, :port, Keyword.get(avm_config, :port, "/dev/ttyUSB0"))
      baud = Map.get(options, :baud, Keyword.get(avm_config, :baud, "115200"))

      flash_offset =
        Map.get(options, :flash_offset, Keyword.get(avm_config, :flash_offset, 0x250000))

      flash(idf_path, chip, port, baud, flash_offset)
    else
      {:atomvm, :error} ->
        IO.puts("error: missing AtomVM project config.")
        exit({:shutdown, 1})

      {:args, :error} ->
        IO.puts("Syntax: ")
        exit({:shutdown, 1})

      {:pack, _} ->
        IO.puts("error: failed PackBEAM, target will not be flashed.")
        exit({:shutdown, 1})
    end
  end

  def flash(idf_path, chip, port, baud, flash_offset) do
    tool_args = [
      "--chip",
      chip,
      "--baud",
      baud,
      "--before",
      "default_reset",
      "--after",
      "hard_reset",
      "write_flash",
      "-u",
      "--flash_mode",
      "keep",
      "--flash_freq",
      "keep",
      "--flash_size",
      "detect",
      "0x#{Integer.to_string(flash_offset, 16)}",
      "#{Project.config()[:app]}.avm"
    ]

    tool_args = if port == "auto", do: tool_args, else: ["--port", port] ++ tool_args

    tool_full_path = get_esptool_path(idf_path)
    System.cmd(tool_full_path, tool_args, stderr_to_stdout: true, into: IO.stream(:stdio, 1))
  end

  defp get_esptool_path(<<"">>) do
    "esptool.py"
  end

  defp get_esptool_path(idf_path) do
    "#{idf_path}#{@esp_tool_path}"
  end

  defp parse_args(args) do
    parse_args(args, %{})
  end

  defp parse_args([], accum) do
    {:ok, accum}
  end

  defp parse_args([<<"--port">>, port | t], accum) do
    parse_args(t, Map.put(accum, :port, port))
  end

  defp parse_args([<<"--baud">>, baud | t], accum) do
    parse_args(t, Map.put(accum, :baud, baud))
  end

  defp parse_args([<<"--chip">>, chip | t], accum) do
    parse_args(t, Map.put(accum, :chip, chip))
  end

  defp parse_args([<<"--flash_offset">>, "0x" <> hex = flash_offset | t], accum) do
    {offset, _} = Integer.parse(hex, 16)
    parse_args(t, Map.put(accum, :flash_offset, offset))
  end

  defp parse_args([_ | t], accum) do
    parse_args(t, accum)
  end
end
