defmodule Mix.Tasks.Atomvm.Esp32.Info do
  @moduledoc """
  Mix task to get information about connected ESP32 devices.
  """
  use Mix.Task
  alias ExAtomVM.EsptoolHelper

  @shortdoc "Get information about connected ESP32 devices"

  @impl Mix.Task
  def run(_args) do
    with :ok <- EsptoolHelper.setup(),
         devices <- EsptoolHelper.connected_devices() do
      case length(devices) do
        0 ->
          IO.puts(
            "Found no esp32 devices..\nYou may have to hold BOOT button down while plugging in the device"
          )

        count ->
          IO.puts("Found #{count} connected esp32:")
      end

      if length(devices) > 1 do
        Enum.each(devices, fn device ->
          IO.puts(
            "#{EsptoolHelper.format_atomvm_status(device["atomvm_installed"])}#{String.pad_trailing(device["chip_family_name"], 8, " ")} - Port: #{device["port"]}"
          )
        end)
      end

      Enum.each(devices, fn device ->
        IO.puts("\n━━━━━━━━━━━━━━━━━━━━━━")

        IO.puts(
          "#{EsptoolHelper.format_atomvm_status(device["atomvm_installed"])}#{device["chip_family_name"]} - Port: #{device["port"]}"
        )

        IO.puts("USB_MODE: #{device["usb_mode"]}")
        IO.puts("MAC: #{device["mac_address"]}")
        IO.puts("AtomVM installed: #{device["atomvm_installed"]}")

        IO.puts("\nBuild Information:")

        Enum.each(format_build_info(device["build_info"]), fn build_info ->
          IO.puts(build_info)
        end)

        IO.puts("\nFeatures:")

        Enum.each(device["features"], fn feature ->
          IO.puts("  · #{feature}")
        end)
      end)

      IO.puts("\n")
    else
      {:error, :pythonx_not_available, message} ->
        IO.puts("\nError: #{message}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts("\nError: Failed to get ESP32 device information")
        IO.puts("Reason: #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp format_build_info(build_info) when is_list(build_info) and length(build_info) == 5 do
    [version, target, time, date, sdk] =
      build_info
      |> Enum.map(&sanitize_string/1)

    [
      "  Version: #{version}",
      "  Target:  #{target}",
      "  Built:   #{time} #{date}",
      "  SDK:     #{sdk}"
    ]
  end

  defp format_build_info(build_info) when is_list(build_info) do
    build_info
    |> Enum.map(&sanitize_string/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {info, index} -> "  Info #{index}: #{info}" end)
  end

  defp format_build_info(_) do
    ["  Build info not available or corrupted"]
  end

  defp sanitize_string(str) when is_binary(str) do
    str
    # Remove non-printable characters while preserving spaces
    |> String.replace(~r/[^\x20-\x7E\s]/u, "")
    |> case do
      "" -> "<unreadable>"
      sanitized -> sanitized
    end
  end

  defp sanitize_string(_), do: "<invalid>"
end
