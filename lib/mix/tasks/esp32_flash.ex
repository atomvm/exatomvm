defmodule Mix.Tasks.Atomvm.Esp32.Flash do
  use Mix.Task
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
