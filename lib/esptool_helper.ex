defmodule ExAtomVM.EsptoolHelper do
  @moduledoc """
  Module for setting up and using esptool through Pythonx.
  """

  @doc """
  Initializes Python environment with project configuration.
  We use locked main branch esptool version, pending a stable 5.x release,
  as we need the read to memory (instead of only to file) features.
  """
  def setup do
    case Code.ensure_loaded(Pythonx) do
      {:module, Pythonx} ->
        Application.ensure_all_started(:pythonx)

        Pythonx.uv_init("""
        [project]
        name = "project"
        version = "0.0.0"
        requires-python = "==3.13.*"
        dependencies = [
          "esptool==5.0.2"
        ]
        """)

      _ ->
        {:error, :pythonx_not_available,
         "The :pythonx dependency is not available. Please add it to your mix.exs dependencies.\n{:pythonx, \"~> 0.4.0\"}"}
    end
  end

  def flash_pythonx(tool_args) do
    # https://github.com/espressif/esptool/blob/master/docs/en/esptool/scripting.rst

    tool_args =
      if not Enum.member?(tool_args, "--port") do
        selected_device = select_device()

        ["--port", selected_device["port"]] ++ tool_args
      else
        tool_args
      end

    {_result, globals} =
      try do
        Pythonx.eval(
          """
          import esptool
          import sys

          command = [arg.decode('utf-8') for arg in tool_args]

          def flash_esp():
              esptool.main(command)

          if __name__ == "__main__":
              try:
                  result = flash_esp()
                  result = True
              except SystemExit as e:
                  exit_code = int(str(e))
                  result = exit_code == 0
              except Exception as e:
                  print(f"Warning: {e}")
                  result = True

          """,
          %{"tool_args" => tool_args}
        )
      rescue
        e in Pythonx.Error ->
          IO.inspect("Pythonx error occurred: #{inspect(e)}")
          exit({:shutdown, 1})
      end

    Pythonx.decode(globals["result"])
  end

  @doc """
  Erases flash of an ESP32 device.
    --after "no-reset" is needed for keeping USB-OTG devices like esp32-S2 in a good state.
  """
  def erase_flash(tool_args \\ ["--chip", "auto", "--after", "no-reset"]) do
    tool_args =
      if not Enum.member?(tool_args, "--port") do
        selected_device = select_device()

        confirmation =
          IO.gets(
            "\nAre you sure you want to erase the flash of\n#{selected_device["chip_family_name"]} - Port: #{selected_device["port"]} MAC: #{selected_device["mac_address"]} ? [N/y]: "
          )

        case String.trim(confirmation) do
          input when input in ["Y", "y"] ->
            IO.puts("Erasing..")

          _ ->
            IO.puts("Flash erase cancelled.")
            exit({:shutdown, 0})
        end

        ["--port", selected_device["port"]] ++ tool_args ++ ["erase-flash"]
      else
        tool_args ++ ["erase-flash"]
      end

    {_result, globals} =
      try do
        Pythonx.eval(
          """
          import esptool

          command = [arg.decode('utf-8') for arg in tool_args]

          def flash_esp():
              esptool.main(command)

          if __name__ == "__main__":
              try:
                  result = flash_esp()
                  result = True
              except SystemExit as e:
                  exit_code = int(str(e))
                  result = exit_code == 0
              except Exception as e:
                  print(f"Warning: {e}")
                  result = False
          """,
          %{"tool_args" => tool_args}
        )
      rescue
        e in Pythonx.Error ->
          IO.inspect("Pythonx error occurred: #{inspect(e)}")
          exit({:shutdown, 1})
      end

    Pythonx.decode(globals["result"])
  end

  def connected_devices do
    {_result, globals} =
      try do
        Pythonx.eval(
          """
          from esptool.cmds import (detect_chip, read_flash, attach_flash)
          import serial.tools.list_ports as list_ports
          import re

          ports = []
          for port in list_ports.comports():
              if port.vid is None:
                  continue
              ports.append(port.device)

          result = []
          for port in ports:
              try:
                  with detect_chip(port) as esp:
                      description = esp.get_chip_description()
                      features = esp.get_chip_features()
                      mac_addr = ':'.join(['%02X' % b for b in esp.read_mac()])

                      # chips like esp32-s2 can have more specific names, so we call this chip family
                      # https://github.com/espressif/esptool/blob/807d02b0c5eb07ba46f871a492c84395fb9f37be/esptool/targets/esp32s2.py#L167
                      chip_family_name = esp.CHIP_NAME

                      # read 128 bytes at 0x10030
                      attach_flash(esp)
                      app_header = read_flash(esp, 0x10030, 128, None)
                      app_header_strings = [s for s in re.split('\\x00', app_header.decode('utf-8', errors='replace')) if s]

                      usb_mode = esp.get_usb_mode()

                      # this is needed to keep USB-OTG boards like esp32-S2 in a good state
                      esp.run_stub()

                      result.append({"port": port, "chip_family_name": chip_family_name,
                        "features": features, "build_info": app_header_strings,
                        "mac_address": mac_addr, "usb_mode": usb_mode
                      })
              except Exception as e:
                  print(f"Error: {e}")
                  result = []
          """,
          %{}
        )
      rescue
        e in Pythonx.Error ->
          {:error, "Pythonx error occurred: #{inspect(e)}"}
      end

    Pythonx.decode(globals["result"])
    |> Enum.map(fn device ->
      Map.put(device, "atomvm_installed", Enum.member?(device["build_info"], "atomvm-esp32"))
    end)
  end

  def select_device do
    devices = connected_devices()

    selected_device =
      case length(devices) do
        0 ->
          IO.puts(
            "Found no esp32 devices..\nYou may have to hold BOOT button down while plugging in the device"
          )

          exit({:shutdown, 1})

        1 ->
          hd(devices)

        _ ->
          IO.puts("\nMultiple ESP32 devices found:")

          devices
          |> Enum.with_index(1)
          |> Enum.each(fn {device, index} ->
            IO.puts(
              "#{index}. #{device["chip_family_name"]} - Port: #{device["port"]} MAC: #{device["mac_address"]}"
            )
          end)

          selected =
            IO.gets("\nSelect device (1-#{length(devices)}): ")
            |> String.trim()
            |> Integer.parse()

          case selected do
            {num, _} when num > 0 and num <= length(devices) ->
              Enum.at(devices, num - 1)

            _ ->
              IO.puts("Invalid selection.")
              exit({:shutdown, 1})
          end
      end

    selected_device
  end
end
