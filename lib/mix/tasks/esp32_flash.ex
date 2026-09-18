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

  The port is detected automatically, and the application is written to the `main.avm`
  partition of the board, found in its partition table. Optional flags override the config in
  mix.exs, for example to name the port

  `
  $ mix atomvm.esp32.flash --port /dev/tty.usbserial-0001
  `

  ## Configuration

  ExAtomVM can be configured from the mix.ex file and supports the following settings for the
  `atomvm.esp32.flash` task.

    * `:esp32_flash_offset` - An address such as `0x250000` to write the application to, instead
      of the `main.avm` partition found on the board. `--flash_offset` overrides it.

    * `:chip` - Chip type, defaults to `auto`.

    * `:port` - The port to which device is connected on the host computer, defaults to `auto`,
      which detects it.

    * `:baud` - The BAUD rate used when flashing to device, defaults to `115200`.

  ## Command line options

  Properties in the mix.exs file may be over-ridden on the command line using long-style flags (prefixed by --) by the same name
  as the [supported properties](#module-configuration)

  For example, you can use the `--port` option to specify or override the port property.
  """

  alias ExAtomVM.Esp32PartitionTable
  alias ExAtomVM.EsptoolHelper
  alias Mix.Project
  alias Mix.Tasks.Atomvm.Packbeam

  @esp_tool_path "/components/esptool_py/esptool/esptool.py"
  @partition_name "main.avm"
  @partition_table_offset 0x8000
  @partition_table_size 0xC00
  @partition_table_file "_build/atomvm_flash/partition_table.bin"
  @pin_hint "Pin the address instead with --flash_offset 0x... or esp32_flash_offset: 0x... in mix.exs."

  def run(args) do
    config = Project.config()

    with {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:args, {:ok, options}} <- {:args, parse_args(args)},
         {:pack, {:ok, _}} <- {:pack, Packbeam.run(args)},
         idf_path <- System.get_env("IDF_PATH", <<"">>) do
      if Keyword.has_key?(avm_config, :flash_offset) do
        IO.puts(
          "warning: flash_offset in mix.exs is ignored; the #{@partition_name} partition of the board is used instead"
        )
      end

      chip = Map.get(options, :chip, Keyword.get(avm_config, :chip, "auto"))
      port = Map.get(options, :port, Keyword.get(avm_config, :port, "auto"))
      baud = Map.get(options, :baud, Keyword.get(avm_config, :baud, "115200"))

      flash(idf_path, chip, port, baud, flash_target(options, avm_config))
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

  @doc false
  def flash_target(options, avm_config) do
    case Map.get(options, :flash_offset, Keyword.get(avm_config, :esp32_flash_offset)) do
      nil ->
        {:partition, @partition_name}

      address when is_integer(address) ->
        {:offset, address}

      other ->
        Mix.raise("esp32_flash_offset must be an address such as 0x250000, got #{inspect(other)}")
    end
  end

  def flash(idf_path, chip, port, baud, target) do
    image = "#{Project.config()[:app]}.avm"

    case Code.ensure_loaded(Pythonx) do
      {:module, Pythonx} ->
        IO.puts("Flashing using Pythonx installed esptool..")
        :ok = EsptoolHelper.setup()
        port = resolve_port(port)
        offsets = resolve_target(target, fn -> read_partition_table_pythonx(port) end)

        # avoid deprecation warnings, as we know we are esptool version 5+, when using Pythonx.
        tool_args =
          Enum.map(["--port", port | write_args(chip, baud, image, offsets)], fn
            "--flash_mode" -> "--flash-mode"
            "--flash_freq" -> "--flash-freq"
            "--flash_size" -> "--flash-size"
            "default_reset" -> "default-reset"
            "hard_reset" -> "hard-reset"
            "write_flash" -> "write-flash"
            arg -> arg
          end)

        case EsptoolHelper.flash_pythonx(tool_args) do
          true -> exit({:shutdown, 0})
          false -> exit({:shutdown, 1})
        end

      _ ->
        IO.puts("Flashing using esptool..")

        offsets =
          resolve_target(target, fn ->
            read_partition_table_esptool(idf_path, port, chip, baud)
          end)

        {_output, status} = esptool(idf_path, port, write_args(chip, baud, image, offsets))
        if status != 0, do: exit({:shutdown, 1})
    end
  end

  defp write_args(chip, baud, image, offsets) do
    [
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
      "detect"
    ] ++ Enum.flat_map(offsets, &[hex(&1), image])
  end

  defp resolve_target({:offset, address}, _read_table), do: [address]

  defp resolve_target({:partition, name}, read_table) do
    with {:ok, table} <- read_table.(),
         {:ok, partition} <- Esp32PartitionTable.find_data_partition(table, name) do
      IO.puts("Found the #{name} partition at #{hex(partition.offset)}")
      [partition.offset]
    else
      {:error, reason} -> fail(target_error(reason))
    end
  end

  defp target_error({:partition_not_found, @partition_name}) do
    "the board has no #{@partition_name} partition, is AtomVM installed? " <>
      "mix atomvm.esp32.install installs it.\n" <> @pin_hint
  end

  defp target_error({:partition_not_found, name}) do
    "the board has no #{name} partition.\n" <> @pin_hint
  end

  defp target_error({:duplicate_partition, name}) do
    "the board has more than one #{name} partition.\n" <> @pin_hint
  end

  defp target_error({:invalid_partition_type, name}) do
    "the #{name} partition of the board is not a data partition.\n" <> @pin_hint
  end

  defp target_error(reason) when reason in [:invalid_partition_table, :corrupt_partition_data] do
    "the partition table read from the board at #{hex(@partition_table_offset)} is invalid.\n" <>
      @pin_hint
  end

  defp target_error({:esptool_exit, status}) do
    "esptool.py could not read the partition table of the board (exit status #{status}).\n" <>
      @pin_hint
  end

  defp target_error({:pythonx_error, message}) do
    "could not read the partition table of the board: #{message}\n" <> @pin_hint
  end

  defp target_error(reason) do
    "could not read the partition table of the board: #{inspect(reason)}\n" <> @pin_hint
  end

  defp read_partition_table_pythonx(port) do
    with {:ok, info} <-
           EsptoolHelper.read_flash_with_size(
             port,
             @partition_table_offset,
             @partition_table_size,
             false
           ) do
      {:ok, info["data"]}
    end
  end

  defp read_partition_table_esptool(idf_path, port, chip, baud) do
    File.mkdir_p!(Path.dirname(@partition_table_file))
    File.rm(@partition_table_file)

    args = [
      "--chip",
      chip,
      "--baud",
      baud,
      "--before",
      "default_reset",
      "--after",
      "no_reset",
      "read_flash",
      hex(@partition_table_offset),
      hex(@partition_table_size),
      @partition_table_file
    ]

    case esptool(idf_path, port, args) do
      {_output, 0} -> File.read(@partition_table_file)
      {_output, status} -> {:error, {:esptool_exit, status}}
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
    device = EsptoolHelper.select_device()

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

  defp fail(message) do
    IO.puts("\nError: #{message}")
    exit({:shutdown, 1})
  end

  defp hex(value), do: "0x" <> Integer.to_string(value, 16)

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

  @doc false
  def parse_args(args) do
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

  defp parse_args([<<"--flash_offset">>, address | t], accum) do
    parse_args(t, Map.put(accum, :flash_offset, parse_address(address)))
  end

  defp parse_args([_ | t], accum) do
    parse_args(t, accum)
  end

  defp parse_address(address) do
    with "0x" <> hex <- address,
         {value, ""} <- Integer.parse(hex, 16) do
      value
    else
      _ -> Mix.raise("--flash_offset expects an address such as 0x250000, got #{address}")
    end
  end
end
