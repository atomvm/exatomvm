defmodule Mix.Tasks.Atomvm.Esp32 do
  @help """
  An application reaches an ESP32 board in three steps.

    1. Install AtomVM on the board, erasing it. This is done once; the
       second command replaces the virtual machine later and keeps the
       application.

           mix atomvm.esp32.install
           mix atomvm.esp32.install --update

    2. Pack the application and write it to the main.avm partition of the
       board.

           mix atomvm.esp32.flash

    3. Reset the board and show its console.

           mix atomvm.esp32.monitor

  Add the optional dependencies to mix.exs:

      {:pythonx, "~> 0.4.0", runtime: false},
      {:req, "~> 0.5.0", runtime: false}

  pythonx brings its own esptool, so none has to be installed by hand, and req
  downloads the images that install writes. Without pythonx only flash and
  build run, flash through an esptool found on PATH or under IDF_PATH.

  The overview lists the tasks that work with any board:

      mix atomvm
  """

  @moduledoc @help

  use Mix.Task

  alias ExAtomVM.TaskHelp

  @shortdoc "Show how to get an application onto an ESP32 board"

  @impl Mix.Task
  def run(_args) do
    TaskHelp.board(@help, "esp32")
  end
end
