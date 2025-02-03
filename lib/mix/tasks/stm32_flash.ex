defmodule Mix.Tasks.Atomvm.Stm32.Flash do
  use Mix.Task

  @shortdoc "Flash the application to a stm32 micro-controller"

  @moduledoc """
  Flashes the application to an stm32 micro-controller.

  > #### Important {: .warning}
  >
  > Before running this task, you must flash the AtomVM virtual machine to the target device.
  >
  > This tasks depends on a host installation of STM32 tooling, see [STM32 Build Instructions ](https://www.atomvm.net/doc/main/build-instructions.html#building-for-stm32)

  ## Usage example

  Within your AtomVM mix project run

  `
  $ mix atomvm.stm32.flash
  `

  Or with optional flags (which will override the config in mix.exs)

  `
  $ mix atomvm.stm32.flash --stflash_path /some/path
  `

  ## Configuration

  ExAtomVM can be configured from the mix.ex file and supports the following settings for the
  `atomvm.stm32.flash` task.

    * `:flash_offset` - The start address of the flash to write the application to in hexademical format,
      defaults to `0x8080000`.

    * `:stflash_path` - The full path to the st-flash utility, if not in users PATH, default `undefined`


  ## Command line options

  Properties in the mix.exs file may be over-ridden on the command line using long-style flags (prefixed by --) by the same name
  as the [supported properties](#module-configuration)

  For example, you can use the `--stflash_path` option to specify or override the `stflash_path` property.
  """

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
