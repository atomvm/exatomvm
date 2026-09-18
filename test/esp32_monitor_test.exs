defmodule Mix.Tasks.Atomvm.Esp32.MonitorTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.Monitor

  @usage "Usage: mix atomvm.esp32.monitor [--port PORT] [--baud RATE] [--no-reset] [--timeout SECONDS]"

  test "rejects arguments, unknown options and values that are not numbers" do
    for args <- [
          ["/dev/ttyACM0"],
          ["--chip", "esp32s3"],
          ["--baud", "fast"],
          ["--timeout", "soon"]
        ] do
      assert_raise Mix.Error, @usage, fn -> Monitor.run(args) end
    end
  end

  test "rejects a baud rate that is not greater than zero" do
    for baud <- ["0", "-115200"] do
      assert_raise Mix.Error, "--baud must be greater than zero", fn ->
        Monitor.run(["--baud", baud])
      end
    end
  end

  test "rejects a timeout that is not greater than zero" do
    for timeout <- ["0", "-1"] do
      assert_raise Mix.Error, "--timeout must be a number of seconds greater than zero", fn ->
        Monitor.run(["--timeout", timeout])
      end
    end
  end

  test "says how long it ran" do
    assert Monitor.stopped_line(1) == "Stopped after 1 second."
    assert Monitor.stopped_line(10) == "Stopped after 10 seconds."
  end
end
