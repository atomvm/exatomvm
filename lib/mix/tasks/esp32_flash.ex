defmodule Mix.Tasks.Atomvm.Esp32.Flash do
  use Mix.Task
  alias Mix.Project
  alias Mix.Tasks.Atomvm.Packbeam

  @esp_tool_path "/components/esptool_py/esptool/esptool.py"

  def run(args) do
    config = Project.config()

    with {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:pack, {:ok, _}} <- {:pack, Packbeam.run(args)},
         idf_path when idf_path != nil <- System.get_env("IDF_PATH") do
      flash_offset = Keyword.get(avm_config, :flash_offset, 0x110000)
      flash(idf_path, flash_offset)
    else
      {:atomvm, :error} ->
        IO.puts("error: missing AtomVM project config.")
        :error

      {:pack, _} ->
        IO.puts("error: failed PackBEAM, target will not be flashed.")
        :error

      nil ->
        IO.puts("error: IDF_PATH env var is not set.")
        :error
    end
  end

  def flash(idf_path, flash_offset) do
    tool_args = [
      "--chip",
      "esp32",
      "--port",
      "/dev/ttyUSB0",
      "--baud",
      "115200",
      "--before",
      "default_reset",
      "--after",
      "hard_reset",
      "write_flash",
      "-u",
      "--flash_mode",
      "dio",
      "--flash_freq",
      "40m",
      "--flash_size",
      "detect",
      "0x#{Integer.to_string(flash_offset, 16)}",
      "#{Project.config()[:app]}.avm"
    ]

    tool_full_path = "#{idf_path}#{@esp_tool_path}"
    System.cmd(tool_full_path, tool_args, stderr_to_stdout: true, into: IO.stream(:stdio, 1))
  end
end
