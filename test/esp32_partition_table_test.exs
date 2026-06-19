defmodule ExAtomVM.Esp32PartitionTableTest do
  use ExUnit.Case, async: true

  alias ExAtomVM.Esp32PartitionTable

  test "expands a final main.avm partition to the detected flash size" do
    partition_table =
      build_partition_table([
        partition("nvs", 0x01, 0x02, 0x9000, 0x4000),
        partition("phy_init", 0x01, 0x01, 0xF000, 0x1000),
        partition("factory", 0x00, 0x00, 0x10000, 0x1F0000),
        partition("boot.avm", 0x01, 0x60, 0x200000, 0x50000),
        partition("main.avm", 0x01, 0x60, 0x250000, 0x100000)
      ])

    assert {:ok, expansion} =
             Esp32PartitionTable.expand_partition(partition_table, "main.avm", 0x1000000)

    assert expansion.changed?
    assert expansion.partition.size == 0x100000
    assert expansion.updated_partition.size == 0xDB0000
    assert byte_size(expansion.partition_table) == 0xC00

    assert {:ok, partitions} = Esp32PartitionTable.parse(expansion.partition_table)

    assert %{offset: 0x250000, size: 0xDB0000} =
             Enum.find(partitions, &(&1.name == "main.avm"))
  end

  test "expands main.avm for 8 MB and 32 MB flash" do
    partition_table =
      build_partition_table([
        partition("factory", 0x00, 0x00, 0x10000, 0x1F0000),
        partition("boot.avm", 0x01, 0x60, 0x200000, 0x50000),
        partition("main.avm", 0x01, 0x60, 0x250000, 0x100000)
      ])

    assert {:ok, %{updated_partition: %{size: 0x5B0000}}} =
             Esp32PartitionTable.expand_partition(partition_table, "main.avm", 0x800000)

    assert {:ok, %{updated_partition: %{size: 0x1DB0000}}} =
             Esp32PartitionTable.expand_partition(partition_table, "main.avm", 0x2000000)
  end

  test "reports an already expanded partition without changing the table" do
    partition_table =
      build_partition_table([
        partition("main.avm", 0x01, 0x60, 0x250000, 0xDB0000)
      ])

    assert {:ok, expansion} =
             Esp32PartitionTable.expand_partition(partition_table, "main.avm", 0x1000000)

    refute expansion.changed?
    assert expansion.partition_table == partition_table
  end

  test "refuses to overwrite a partition following main.avm" do
    partition_table =
      build_partition_table([
        partition("main.avm", 0x01, 0x60, 0x250000, 0x100000),
        partition("storage", 0x01, 0x40, 0x350000, 0x100000)
      ])

    assert {:error, {:partition_not_last, "main.avm", "storage"}} =
             Esp32PartitionTable.expand_partition(partition_table, "main.avm", 0x1000000)
  end

  test "refuses a table that extends beyond physical flash" do
    partition_table =
      build_partition_table([
        partition("factory", 0x00, 0x00, 0x10000, 0xF0000),
        partition("main.avm", 0x01, 0x60, 0x100000, 0x400000)
      ])

    assert {:error, {:partition_exceeds_flash, "main.avm"}} =
             Esp32PartitionTable.expand_partition(partition_table, "main.avm", 0x400000)
  end

  test "refuses a corrupt checksum" do
    partition_table =
      build_partition_table([
        partition("main.avm", 0x01, 0x60, 0x250000, 0x100000)
      ])

    <<head::binary-size(48), _digest_byte, rest::binary>> = partition_table
    corrupt_table = head <> <<0>> <> rest

    assert {:error, :invalid_partition_table} =
             Esp32PartitionTable.expand_partition(corrupt_table, "main.avm", 0x1000000)
  end

  defp build_partition_table(entries) do
    data = IO.iodata_to_binary(entries)
    md5_entry = <<0xEB, 0xEB>> <> :binary.copy(<<0xFF>>, 14) <> :crypto.hash(:md5, data)

    data <>
      md5_entry <>
      :binary.copy(<<0xFF>>, 0xC00 - byte_size(data) - byte_size(md5_entry))
  end

  defp partition(name, type, subtype, offset, size) do
    label = name <> :binary.copy(<<0>>, 16 - byte_size(name))

    <<0xAA, 0x50, type, subtype, offset::little-unsigned-32, size::little-unsigned-32,
      label::binary-size(16), 0::little-unsigned-32>>
  end
end
