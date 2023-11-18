defmodule Mix.Tasks.Atomvm.Stm32.Flash do
  use Mix.Task
  alias Mix.Project
  alias Mix.Tasks.Atomvm.Packbeam

  def run(args) do
    config = Project.config()

    with {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:args, {:ok, options}} <- {:args, parse_args(args)},
         {:pack, {:ok, _}} <- {:pack, Packbeam.run(args)},
         stflash_path <- System.get_env("ATOMVM_MIX_PLUGIN_STFLASH", <<"">>) do

      flash_offset =
        Map.get(options, :flash_offset, Keyword.get(avm_config, :flash_offset, 0x8080000))

      flash(stflash_path, flash_offset)
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

  def flash(stflash_path, flash_offset) do
    tool_args = [
      "--reset",
      "write",
      "#{Project.config()[:app]}.avm",
      "0x#{Integer.to_string(flash_offset, 16)}"
    ]

    tool_full_path = get_stflash_path(stflash_path)
    System.cmd(tool_full_path, tool_args, stderr_to_stdout: true, into: IO.stream(:stdio, 1))
  end

  defp get_stflash_path(<<"">>) do
    "st-flash"
  end

  defp parse_args(args) do
    parse_args(args, %{})
  end

  defp parse_args([], accum) do
    {:ok, accum}
  end

  defp parse_args([<<"--flash_offset">>, flash_offset | t], accum) do
    parse_args(t, Map.put(accum, :flash_offset, flash_offset))
  end

  defp parse_args([_ | t], accum) do
    parse_args(t, accum)
  end
end
