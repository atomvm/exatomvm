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
          "esptool==5.3.0"
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

        if not Map.get(selected_device, "atomvm_installed", false) do
          IO.puts("""

            AtomVM doesn't seem to be installed on #{selected_device["chip_family_name"]}!

            Install using 'mix atomvm.esp32.install' or

            https://doc.atomvm.org/main/getting-started-guide.html#flashing-a-binary-image-to-esp32

            (override check using 'mix atomvm.esp32.flash --port #{selected_device["port"]}')
          """)

          exit({:shutdown, 1})
        end

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

  def read_flash_with_size(port, address, size, reset_after \\ false) do
    case (try do
            Pythonx.eval(
              """
              from esptool.cmds import (
                  attach_flash,
                  detect_chip,
                  detect_flash_size,
                  read_flash,
                  reset_chip,
              )
              from esptool.util import flash_size_bytes

              port = port.decode("utf-8")

              with detect_chip(port) as esp:
                  attach_flash(esp)
                  try:
                      flash_size_name = detect_flash_size(esp)
                      if flash_size_name is None:
                          raise RuntimeError("Unable to detect flash size")

                      data = read_flash(
                          esp,
                          address,
                          size,
                          None,
                          flash_size=flash_size_name,
                          no_progress=True,
                      )
                      result = {
                          "bootloader_offset": esp.BOOTLOADER_FLASH_OFFSET,
                          "chip_name": esp.CHIP_NAME,
                          "data": data,
                          "flash_size": flash_size_bytes(flash_size_name),
                          "flash_size_id": esp.parse_flash_size_arg(flash_size_name),
                          "flash_size_name": flash_size_name,
                      }
                  finally:
                      if reset_after:
                          reset_chip(esp, "hard-reset")

                  if not reset_after:
                      # Keep USB-OTG devices such as ESP32-S2 in a usable state.
                      esp.run_stub()
              """,
              %{
                "address" => address,
                "port" => port,
                "reset_after" => reset_after,
                "size" => size
              }
            )
          rescue
            e in Pythonx.Error ->
              {:error, {:pythonx_error, "Pythonx error occurred: #{inspect(e)}"}}
          end) do
      {_result, %{"result" => result}} ->
        {:ok, Pythonx.decode(result)}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :flash_read_failed}
    end
  end

  def write_flash_data(port, address, data) when is_binary(data) do
    case (try do
            Pythonx.eval(
              """
              from esptool.cmds import attach_flash, detect_chip, reset_chip, write_flash

              port = port.decode("utf-8")

              with detect_chip(port) as esp:
                  attach_flash(esp)
                  try:
                      write_flash(esp, [(address, data)], flash_size="keep")
                      result = True
                  finally:
                      reset_chip(esp, "hard-reset")
              """,
              %{"address" => address, "data" => data, "port" => port}
            )
          rescue
            e in Pythonx.Error ->
              {:error, {:pythonx_error, "Pythonx error occurred: #{inspect(e)}"}}
          end) do
      {_result, %{"result" => result}} ->
        {:ok, Pythonx.decode(result)}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :flash_write_failed}
    end
  end

  def write_flash_size_and_partition(
        port,
        bootloader_offset,
        bootloader,
        partition_table_offset,
        partition_table,
        flash_size_name
      )
      when is_binary(bootloader) and is_binary(partition_table) do
    case (try do
            Pythonx.eval(
              """
              from esptool.cmds import (
                  _update_image_flash_params,
                  attach_flash,
                  detect_chip,
                  detect_flash_size,
                  reset_chip,
                  write_flash,
              )

              port = port.decode("utf-8")
              flash_size_name = flash_size_name.decode("utf-8")

              with detect_chip(port) as esp:
                  attach_flash(esp)
                  try:
                      if esp.BOOTLOADER_FLASH_OFFSET != bootloader_offset:
                          raise RuntimeError(
                              f"Unexpected bootloader offset {bootloader_offset:#x}; "
                              f"{esp.CHIP_NAME} uses {esp.BOOTLOADER_FLASH_OFFSET:#x}"
                          )
                      if esp.secure_download_mode or esp.get_secure_boot_enabled():
                          raise RuntimeError(
                              "Cannot update the flash-size header when secure boot "
                              "or secure download mode is enabled"
                          )

                      detected_size = detect_flash_size(esp)
                      if detected_size != flash_size_name:
                          raise RuntimeError(
                              f"Flash size changed from {flash_size_name} "
                              f"to {detected_size or 'unknown'}"
                          )

                      updated_bootloader = _update_image_flash_params(
                          esp,
                          bootloader_offset,
                          "keep",
                          "keep",
                          flash_size_name,
                          bootloader,
                      )
                      expected_size_id = esp.parse_flash_size_arg(flash_size_name)
                      if updated_bootloader[0] != esp.ESP_IMAGE_MAGIC:
                          raise RuntimeError("Invalid bootloader image header")
                      if updated_bootloader[3] & 0xF0 != expected_size_id:
                          raise RuntimeError("Failed to update bootloader flash-size header")

                      write_flash(
                          esp,
                          [
                              (bootloader_offset, updated_bootloader),
                              (partition_table_offset, partition_table),
                          ],
                          flash_size="keep",
                      )
                      result = True
                  finally:
                      reset_chip(esp, "hard-reset")
              """,
              %{
                "bootloader" => bootloader,
                "bootloader_offset" => bootloader_offset,
                "flash_size_name" => flash_size_name,
                "partition_table" => partition_table,
                "partition_table_offset" => partition_table_offset,
                "port" => port
              }
            )
          rescue
            e in Pythonx.Error ->
              {:error, {:pythonx_error, "Pythonx error occurred: #{inspect(e)}"}}
          end) do
      {_result, %{"result" => result}} ->
        {:ok, Pythonx.decode(result)}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :flash_write_failed}
    end
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
              "#{index}. #{String.pad_trailing(device["chip_family_name"], 8, " ")} MAC: #{device["mac_address"]} AtomVM installed: #{format_atomvm_status(device["atomvm_installed"])} - Port: #{device["port"]}"
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

  def format_atomvm_status(true), do: "✅"
  def format_atomvm_status(_), do: "❌"
end
