defmodule Mix.Tasks.Atomvm do
  @help """
  An application reaches a board in three steps.

    1. Name the module AtomVM starts in the atomvm section of mix.exs.

           atomvm: [start: MyProject]

       That module must define start/0, which AtomVM calls when the board
       boots.

    2. Install AtomVM on the board. This is done once.

    3. Flash the application, then watch its console.

  Steps 2 and 3 differ from board to board:

      mix atomvm.esp32
      mix atomvm.stm32
      mix atomvm.pico

  Each task documents its own options:

      mix help TASK
  """

  @moduledoc @help

  use Mix.Task

  alias ExAtomVM.TaskHelp

  @shortdoc "Show how to get an application onto a board"

  @impl Mix.Task
  def run(_args) do
    TaskHelp.overview(@help)
  end
end
