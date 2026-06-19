defmodule Mix.Tasks.Atomvm.Esp32.Expand do
  @moduledoc """
  Expands the `main.avm` partition to the end of the detected ESP32 flash.

  The task updates the flash size in the bootloader image header, preserves all
  partition offsets and data, and updates the size of a final data partition
  named `main.avm` and the partition table checksum.

  ## Options

    * `--port` - Serial port to use. Defaults to the configured AtomVM port,
      or automatic device selection when no port is configured.

  ## Example

      mix atomvm.esp32.expand
      mix atomvm.esp32.expand --port /dev/tty.usbserial-0001
  """

  use Mix.Task

  alias ExAtomVM.Esp32ImageHeader
  alias ExAtomVM.Esp32PartitionTable
  alias ExAtomVM.EsptoolHelper

  @shortdoc "Expand the ESP32 main.avm partition to fill flash"
  @partition_name "main.avm"
  @partition_table_offset 0x8000
  @partition_table_size 0xC00

  @impl Mix.Task
  def run(args) do
    {opts, remaining, invalid} = OptionParser.parse(args, strict: [port: :string])

    if remaining != [] or invalid != [] do
      Mix.raise("Usage: mix atomvm.esp32.expand [--port PORT]")
    end

    with :ok <- EsptoolHelper.setup(),
         port <- resolve_port(Keyword.get(opts, :port, configured_port())),
         {:ok, flash_info} <-
           EsptoolHelper.read_flash_with_size(
             port,
             @partition_table_offset,
             @partition_table_size,
             true
           ),
         {:ok, expansion} <-
           Esp32PartitionTable.expand_partition(
             flash_info["data"],
             @partition_name,
             flash_info["flash_size"]
           ),
         {:ok, bootloader_info} <- read_bootloader(port, flash_info),
         {:ok, bootloader_flash_size} <-
           Esp32ImageHeader.flash_size(bootloader_info["data"]) do
      print_expansion(port, flash_info, bootloader_flash_size, expansion)
      apply_expansion(port, flash_info, bootloader_info, bootloader_flash_size, expansion)
    else
      {:error, :pythonx_not_available, message} ->
        Mix.raise(message)

      {:error, reason} ->
        raise_expand_error(reason)
    end
  end

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

  defp read_bootloader(port, flash_info) do
    bootloader_offset = flash_info["bootloader_offset"]
    bootloader_size = @partition_table_offset - bootloader_offset

    if bootloader_size <= 0 do
      {:error, :invalid_bootloader_offset}
    else
      EsptoolHelper.read_flash_with_size(port, bootloader_offset, bootloader_size, true)
    end
  end

  defp print_expansion(port, flash_info, bootloader_flash_size, expansion) do
    partition = expansion.partition
    updated_partition = expansion.updated_partition

    IO.puts("""

    ESP32: #{flash_info["chip_name"]} on #{port}
    Detected flash: #{flash_info["flash_size_name"]} (#{hex(flash_info["flash_size"])})
    Bootloader flash size: #{format_size(bootloader_flash_size)}
    #{@partition_name} offset: #{hex(partition.offset)}
    Current size: #{format_size(partition.size)}
    Expanded size: #{format_size(updated_partition.size)}
    """)
  end

  defp apply_expansion(
         _port,
         %{"flash_size" => flash_size},
         _bootloader_info,
         flash_size,
         %{changed?: false}
       ) do
    IO.puts("Bootloader and #{@partition_name} already use the detected flash size.")
    :ok
  end

  defp apply_expansion(port, flash_info, bootloader_info, _bootloader_flash_size, expansion) do
    with {:ok, true} <-
           EsptoolHelper.write_flash_size_and_partition(
             port,
             flash_info["bootloader_offset"],
             bootloader_info["data"],
             @partition_table_offset,
             expansion.partition_table,
             flash_info["flash_size_name"]
           ),
         {:ok, bootloader_verification} <-
           EsptoolHelper.read_flash_with_size(
             port,
             flash_info["bootloader_offset"],
             24,
             true
           ),
         {:ok, partition_verification} <-
           EsptoolHelper.read_flash_with_size(
             port,
             @partition_table_offset,
             @partition_table_size,
             true
           ),
         {:ok, flash_size_id} <-
           Esp32ImageHeader.flash_size_id(bootloader_verification["data"]),
         true <- flash_size_id == flash_info["flash_size_id"],
         true <- partition_verification["data"] == expansion.partition_table do
      IO.puts(
        "Updated the bootloader flash size, expanded #{@partition_name}, and verified both."
      )

      :ok
    else
      {:error, reason} -> raise_expand_error(reason)
      false -> Mix.raise("Bootloader or partition table verification failed after flashing.")
      other -> Mix.raise("Failed to update the partition table: #{inspect(other)}")
    end
  end

  defp raise_expand_error(:invalid_partition_table) do
    Mix.raise("The ESP32 returned an invalid partition table from flash offset 0x8000.")
  end

  defp raise_expand_error(:corrupt_partition_data) do
    Mix.raise("The partition table at flash offset 0x8000 contains corrupt data.")
  end

  defp raise_expand_error({:partition_not_found, @partition_name}) do
    Mix.raise("The device partition table does not contain a #{@partition_name} partition.")
  end

  defp raise_expand_error({:duplicate_partition, @partition_name}) do
    Mix.raise("The device partition table contains more than one #{@partition_name} partition.")
  end

  defp raise_expand_error({:invalid_partition_type, @partition_name}) do
    Mix.raise("The #{@partition_name} entry is not a data partition.")
  end

  defp raise_expand_error({:partition_not_last, @partition_name, next_partition}) do
    Mix.raise("""
    Cannot expand #{@partition_name} because partition #{next_partition} follows it.
    Expanding it would overwrite another partition.
    """)
  end

  defp raise_expand_error({:partition_exceeds_flash, partition}) do
    Mix.raise("Partition #{partition} extends beyond the detected physical flash.")
  end

  defp raise_expand_error({:overlapping_partitions, first, second}) do
    Mix.raise("Partitions #{first} and #{second} overlap; refusing to modify the table.")
  end

  defp raise_expand_error(:invalid_flash_size) do
    Mix.raise("Esptool returned an invalid physical flash size.")
  end

  defp raise_expand_error(:invalid_bootloader_offset) do
    Mix.raise("Esptool returned an invalid bootloader offset.")
  end

  defp raise_expand_error(:invalid_image_header) do
    Mix.raise("The ESP32 bootloader image header is invalid.")
  end

  defp raise_expand_error(:unsupported_flash_size) do
    Mix.raise("The ESP32 bootloader declares an unsupported flash size.")
  end

  defp raise_expand_error({:pythonx_error, message}), do: Mix.raise(message)
  defp raise_expand_error(:flash_read_failed), do: Mix.raise("Failed to read ESP32 flash.")
  defp raise_expand_error(:flash_write_failed), do: Mix.raise("Failed to write ESP32 flash.")

  defp raise_expand_error(reason) do
    Mix.raise("Unable to expand #{@partition_name}: #{inspect(reason)}")
  end

  defp format_size(bytes) do
    "#{bytes} bytes (#{hex(bytes)})"
  end

  defp hex(value), do: "0x" <> String.upcase(Integer.to_string(value, 16))
end
