defmodule Mix.Tasks.Atomvm.Esp32.EraseFlash do
  @moduledoc """
  Mix task to get erase the flash of an connected ESP32 devices.
  """
  use Mix.Task

  @shortdoc "Erase flash of ESP32"

  @impl Mix.Task
  def run(_args) do
    with :ok <- ExAtomVM.EsptoolHelper.setup(),
         result <- ExAtomVM.EsptoolHelper.erase_flash() do
      case result do
        true -> exit({:shutdown, 0})
        false -> exit({:shutdown, 1})
      end
    else
      {:error, :pythonx_not_available, message} ->
        IO.puts("\nError: #{message}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts("Error: #{reason}")
        exit({:shutdown, 1})
    end
  end
end
