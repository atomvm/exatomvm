defmodule Mix.Tasks.Atomvm.Stm32 do
  @help """
  An application reaches an STM32 board in two steps.

    1. Install AtomVM on the board. There is no task for it; the AtomVM
       documentation describes how to build and flash the virtual machine:
       https://www.atomvm.net/doc/main/build-instructions.html#building-for-stm32

    2. Pack the application and write it with st-flash, at 0x8080000 or at
       the stm32_flash_offset given in mix.exs.

           mix atomvm.stm32.flash

  st-flash comes with stlink; stflash_path in mix.exs names it when it is not
  on PATH.

  The overview lists the tasks that work with any board:

      mix atomvm
  """

  @moduledoc @help

  use Mix.Task

  alias ExAtomVM.TaskHelp

  @shortdoc "Show how to get an application onto an STM32 board"

  @impl Mix.Task
  def run(_args) do
    TaskHelp.board(@help, "stm32")
  end
end
