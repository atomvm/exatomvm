defmodule Mix.Tasks.Atomvm.Pico do
  @help """
  An application reaches a Raspberry Pi Pico in two steps.

    1. Install AtomVM on the board: hold BOOTSEL down while plugging it in,
       then copy the AtomVM uf2 file of a release onto the drive that appears.
       The AtomVM documentation describes it:
       https://www.atomvm.net/doc/main/getting-started-guide.html

    2. Pack the application, turn it into a uf2 file and copy it to the
       mounted board.

           mix atomvm.pico.flash

  To make the uf2 file without copying it to a board:

      mix atomvm.uf2create

  pico_path in mix.exs names the mount point of the board and pico_reset the
  device to reset before copying, when the defaults do not fit.

  The overview lists the tasks that work with any board:

      mix atomvm
  """

  @moduledoc @help

  use Mix.Task

  alias ExAtomVM.TaskHelp

  @shortdoc "Show how to get an application onto a Raspberry Pi Pico"

  @impl Mix.Task
  def run(_args) do
    TaskHelp.board(@help, "pico")
  end
end
