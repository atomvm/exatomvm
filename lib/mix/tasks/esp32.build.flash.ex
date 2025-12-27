defmodule Mix.Tasks.Atomvm.Esp32.Build.Flash do
  @moduledoc """
  Mix task for flashing a custom-built AtomVM image to ESP32.

  ## Options

    * `--image` - Path to the AtomVM .img file to flash (required)
    * `--port` - Serial port to use (optional, will auto-detect if not provided)
    * `--baud` - Baud rate for flashing (default: 921600)
    * `--erase` - Erase flash before flashing (default: false)

  ## Examples

      # Flash with auto-detection
      mix atomvm.esp32.build.flash --image /path/to/AtomVM-esp32s3.img

      # Flash with erase and custom baud rate
      mix atomvm.esp32.build.flash --image /path/to/AtomVM-esp32s3.img --erase --baud 115200

      # Flash to specific port
      mix atomvm.esp32.build.flash --image /path/to/AtomVM-esp32s3.img --port /dev/ttyUSB0

  """
  use Mix.Task

  @shortdoc "Flash custom-built AtomVM image to ESP32"

  alias ExAtomVM.EsptoolHelper

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          image: :string,
          port: :string,
          baud: :string,
          erase: :boolean
        ]
      )

    image_path = Keyword.get(opts, :image)
    port = Keyword.get(opts, :port)
    baud = Keyword.get(opts, :baud, "921600")
    erase = Keyword.get(opts, :erase, false)

    unless image_path do
      IO.puts("""
      Error: --image option is required

      Usage:
        mix atomvm.esp32.build.flash --image /path/to/AtomVM-esp32s3.img

      """)

      exit({:shutdown, 1})
    end

    unless File.exists?(image_path) do
      IO.puts("Error: Image file not found: #{image_path}")
      exit({:shutdown, 1})
    end

    with :ok <- EsptoolHelper.setup() do
      device =
        if port do
          # Use specified port
          %{"port" => port, "chip_family_name" => "Custom"}
        else
          # Auto-detect device
          EsptoolHelper.select_device()
        end

      flash_offset = detect_flash_offset(device["chip_family_name"])

      IO.puts("""

      Flashing AtomVM to #{device["chip_family_name"]}
      Port: #{device["port"]}
      Image: #{image_path}
      Flash offset: #{flash_offset}
      Baud rate: #{baud}

      """)

      if erase do
        IO.puts("Erasing flash...")

        EsptoolHelper.erase_flash([
          "--port",
          device["port"],
          "--chip",
          "auto",
          "--after",
          "no-reset"
        ])

        :timer.sleep(3000)
      end

      tool_args = [
        "--chip",
        "auto",
        "--port",
        device["port"],
        "--baud",
        baud,
        "write-flash",
        flash_offset,
        image_path
      ]

      case EsptoolHelper.flash_pythonx(tool_args) do
        true ->
          IO.puts("""

          ✅ Successfully flashed AtomVM to #{device["chip_family_name"]}

          Your project can now be flashed with:
            mix atomvm.esp32.flash

          """)

        false ->
          IO.puts("Error: Flash failed")
          exit({:shutdown, 1})
      end
    else
      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp detect_flash_offset(chip_family) do
    %{
      "ESP32" => "0x1000",
      "ESP32-S2" => "0x1000",
      "ESP32-S3" => "0x0",
      "ESP32-C2" => "0x0",
      "ESP32-C3" => "0x0",
      "ESP32-C6" => "0x0",
      "ESP32-H2" => "0x0",
      "ESP32-P4" => "0x2000"
    }[chip_family] || "0x0"
  end
end
