defmodule Mix.Tasks.Atomvm.Esp32.Monitor do
  @moduledoc """
  Shows the console output of an ESP32 board.

  The port is opened without resetting the board, then the board is reset so
  that its output is shown from the boot messages on; `--no-reset` leaves it
  running instead. A board that disappears, as boards connected through their
  native USB port do while they reset, is waited for. The task runs until
  Ctrl+C, pressed twice, or for `--timeout` seconds.

  The optional `pythonx` dependency is needed:

      {:pythonx, "~> 0.4.0", runtime: false}

  ## Options

    * `--port` - Serial port to use. Defaults to the configured AtomVM port,
      or automatic device selection when no port is configured.
    * `--baud` - Baud rate of the console, 115200 by default. The `baud` key
      of `mix.exs` is the flashing speed and does not apply.
    * `--no-reset` - Do not reset the board, show its output from now on.
    * `--timeout` - Stop after this many seconds, for scripts.

  ## Examples

      mix atomvm.esp32.monitor
      mix atomvm.esp32.monitor --no-reset
      mix atomvm.esp32.monitor --port /dev/ttyACM0 --timeout 10
  """

  use Mix.Task

  alias ExAtomVM.EsptoolHelper

  @shortdoc "Show the console output of an ESP32 board"

  @usage "mix atomvm.esp32.monitor [--port PORT] [--baud RATE] [--no-reset] [--timeout SECONDS]"

  @impl Mix.Task
  def run(args) do
    {opts, remaining, invalid} =
      OptionParser.parse(args,
        strict: [port: :string, baud: :integer, no_reset: :boolean, timeout: :integer]
      )

    if remaining != [] or invalid != [] do
      Mix.raise("Usage: #{@usage}")
    end

    baud = Keyword.get(opts, :baud, 115_200)
    timeout = Keyword.get(opts, :timeout)

    if baud < 1, do: Mix.raise("--baud must be greater than zero")

    if timeout != nil and timeout < 1 do
      Mix.raise("--timeout must be a number of seconds greater than zero")
    end

    with :ok <- EsptoolHelper.setup(),
         port <- resolve_port(Keyword.get(opts, :port, configured_port())),
         :ok <-
           EsptoolHelper.monitor(port, baud,
             reset: not Keyword.get(opts, :no_reset, false),
             timeout: timeout
           ) do
      IO.puts(stopped_line(timeout))
    else
      {:error, :pythonx_not_available, message} ->
        Mix.raise(message)

      {:error, {_reason, message}} ->
        Mix.raise(message)
    end
  end

  @doc false
  def stopped_line(1), do: "Stopped after 1 second."
  def stopped_line(seconds), do: "Stopped after #{seconds} seconds."

  defp configured_port do
    Mix.Project.config()
    |> Keyword.get(:atomvm, [])
    |> Keyword.get(:port, "auto")
  end

  defp resolve_port("auto") do
    EsptoolHelper.select_device()
    |> Map.fetch!("port")
  end

  defp resolve_port(port), do: port
end
