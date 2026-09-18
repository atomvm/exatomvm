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

  The port is detected automatically. Optional flags override the config in mix.exs, for
  example to name the port

  `
  $ mix atomvm.esp32.flash --port /dev/tty.usbserial-0001
  `

  ## Configuration

  ExAtomVM can be configured from the mix.ex file and supports the following settings for the
  `atomvm.esp32.flash` task.

    * `:esp32_flash_offset` - The start address of the flash to write the application to in hexadecimal
      format, defaults to `0x250000`. `--flash_offset` overrides it.

    * `:chip` - Chip type, defaults to `auto`.

    * `:port` - The port to which device is connected on the host computer, defaults to `auto`,
      which detects it.

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
      if Keyword.has_key?(avm_config, :flash_offset) do
        IO.puts("warning: flash_offset in mix.exs is ignored, use esp32_flash_offset")
      end

      chip = Map.get(options, :chip, Keyword.get(avm_config, :chip, "auto"))
      port = Map.get(options, :port, Keyword.get(avm_config, :port, "auto"))
      baud = Map.get(options, :baud, Keyword.get(avm_config, :baud, "115200"))

      flash_offset =
        Map.get(options, :flash_offset, Keyword.get(avm_config, :esp32_flash_offset, 0x250000))

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

    case Code.ensure_loaded(Pythonx) do
      {:module, Pythonx} ->
        IO.puts("Flashing using Pythonx installed esptool..")
        :ok = ExAtomVM.EsptoolHelper.setup()
        port = resolve_port(port)

        # avoid deprecation warnings, as we know we are esptool version 5+, when using Pythonx.
        tool_args =
          Enum.map(["--port", port | tool_args], fn
            "--flash_mode" -> "--flash-mode"
            "--flash_freq" -> "--flash-freq"
            "--flash_size" -> "--flash-size"
            "default_reset" -> "default-reset"
            "hard_reset" -> "hard-reset"
            "write_flash" -> "write-flash"
            arg -> arg
          end)

        case ExAtomVM.EsptoolHelper.flash_pythonx(tool_args) do
          true -> exit({:shutdown, 0})
          false -> exit({:shutdown, 1})
        end

      _ ->
        IO.puts("Flashing using esptool..")
        {_output, status} = esptool(idf_path, port, tool_args)
        if status != 0, do: exit({:shutdown, 1})
    end
  end

  defp esptool(idf_path, port, args) do
    tool_full_path = get_esptool_path(idf_path)
    {tool_exec, prefix_args} = resolve_esptool_exec(tool_full_path, idf_path)

    System.cmd(tool_exec, prefix_args ++ port_args(port) ++ args,
      stderr_to_stdout: true,
      into: IO.stream(:stdio, 1)
    )
  end

  defp resolve_port("auto") do
    device = ExAtomVM.EsptoolHelper.select_device()

    if not Map.get(device, "atomvm_installed", false) do
      IO.puts("""

        AtomVM doesn't seem to be installed on #{device["chip_family_name"]}!

        Install using 'mix atomvm.esp32.install' or

        https://doc.atomvm.org/main/getting-started-guide.html#flashing-a-binary-image-to-esp32

        (override check using 'mix atomvm.esp32.flash --port #{device["port"]}')
      """)

      exit({:shutdown, 1})
    end

    device["port"]
  end

  defp resolve_port(port), do: port

  defp port_args("auto"), do: []
  defp port_args(port), do: ["--port", port]

  defp get_esptool_path(<<"">>) do
    "esptool.py"
  end

  defp get_esptool_path(idf_path) do
    "#{idf_path}#{@esp_tool_path}"
  end

  defp resolve_esptool_exec(tool_full_path, <<"">>) do
    # IDF_PATH is not set: run esptool from PATH (usually "esptool.py").
    {tool_full_path, []}
  end

  defp resolve_esptool_exec(tool_full_path, _idf_path) do
    # IDF_PATH is set: tool_full_path is ESP-IDF's esptool.py.
    # Some ESP-IDF installs ship it without the executable bit, so run it via python.
    if not File.exists?(tool_full_path) do
      Mix.raise("""
      IDF_PATH is set, but esptool.py was not found: #{tool_full_path}
      Try: env -u IDF_PATH mix atomvm.esp32.flash ...  (or install esptool)
      """)
    end

    python = System.find_executable("python") || System.find_executable("python3")

    if is_nil(python) do
      Mix.raise("""
      IDF_PATH is set, but python is missing from PATH
      Try: env -u IDF_PATH mix atomvm.esp32.flash ...  (or install python3)
      """)
    end

    {python, [tool_full_path]}
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

  defp parse_args([<<"--flash_offset">>, "0x" <> hex = _flash_offset | t], accum) do
    {offset, _} = Integer.parse(hex, 16)
    parse_args(t, Map.put(accum, :flash_offset, offset))
  end

  defp parse_args([_ | t], accum) do
    parse_args(t, accum)
  end
end
