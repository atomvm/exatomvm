defmodule ExAtomVM.Esp32PartitionTable do
  @moduledoc false

  @entry_size 32
  @data_partition_type 0x01
  @erased_entry :binary.copy(<<0xFF>>, @entry_size)
  @md5_prefix <<0xEB, 0xEB>> <> :binary.copy(<<0xFF>>, 14)

  def expand_partition(partition_table, partition_name, flash_size)
      when is_binary(partition_table) and is_binary(partition_name) and is_integer(flash_size) do
    with {:ok, records, partitions} <- parse_records(partition_table),
         {:ok, partition} <- find_partition(partitions, partition_name),
         :ok <- validate_partition(partition, partitions, flash_size) do
      new_size = flash_size - partition.offset
      updated_partition = %{partition | size: new_size}

      {:ok,
       %{
         changed?: new_size != partition.size,
         partition: partition,
         updated_partition: updated_partition,
         partition_table: rebuild(records, partition.entry_offset, new_size)
       }}
    end
  end

  def expand_partition(_partition_table, _partition_name, _flash_size) do
    {:error, :invalid_arguments}
  end

  def parse(partition_table) when is_binary(partition_table) do
    with {:ok, _records, partitions} <- parse_records(partition_table) do
      {:ok, partitions}
    end
  end

  defp parse_records(partition_table) do
    if rem(byte_size(partition_table), @entry_size) == 0 do
      parse_records(partition_table, 0, [], [], [])
    else
      {:error, :invalid_partition_table}
    end
  end

  defp parse_records(<<>>, _entry_offset, _segment, _records, _partitions) do
    {:error, :invalid_partition_table}
  end

  defp parse_records(
         <<entry::binary-size(@entry_size), rest::binary>> = remaining,
         entry_offset,
         segment,
         records,
         partitions
       ) do
    cond do
      entry == @erased_entry ->
        {:ok, Enum.reverse([{:tail, remaining} | records]), Enum.reverse(partitions)}

      md5_entry?(entry) ->
        with :ok <- verify_md5(entry, segment) do
          parse_records(
            rest,
            entry_offset + @entry_size,
            [],
            [{:md5, entry} | records],
            partitions
          )
        end

      true ->
        with {:ok, partition} <- parse_partition(entry, entry_offset) do
          parse_records(
            rest,
            entry_offset + @entry_size,
            [entry | segment],
            [{:partition, partition, entry} | records],
            [partition | partitions]
          )
        end
    end
  end

  defp parse_partition(
         <<0xAA, 0x50, type, subtype, offset::little-unsigned-32, size::little-unsigned-32,
           label::binary-size(16), flags::little-unsigned-32>>,
         entry_offset
       ) do
    {:ok,
     %{
       entry_offset: entry_offset,
       flags: flags,
       name: decode_label(label),
       offset: offset,
       size: size,
       subtype: subtype,
       type: type
     }}
  end

  defp parse_partition(_entry, _entry_offset), do: {:error, :corrupt_partition_data}

  defp md5_entry?(<<@md5_prefix::binary, _digest::binary-size(16)>>), do: true
  defp md5_entry?(_entry), do: false

  defp verify_md5(<<@md5_prefix::binary, digest::binary-size(16)>>, segment) do
    if digest == segment_digest(segment) do
      :ok
    else
      {:error, :invalid_partition_table}
    end
  end

  defp find_partition(partitions, partition_name) do
    case Enum.filter(partitions, &(&1.name == partition_name)) do
      [partition] -> {:ok, partition}
      [] -> {:error, {:partition_not_found, partition_name}}
      _partitions -> {:error, {:duplicate_partition, partition_name}}
    end
  end

  defp validate_partition(partition, partitions, flash_size) do
    with :ok <- validate_data_partition(partition),
         :ok <- validate_flash_size(flash_size),
         :ok <- validate_layout(partitions, flash_size),
         :ok <- validate_last_partition(partition, partitions),
         :ok <- validate_expansion(partition, flash_size) do
      :ok
    end
  end

  defp validate_data_partition(%{type: @data_partition_type}), do: :ok

  defp validate_data_partition(%{name: name}) do
    {:error, {:invalid_partition_type, name}}
  end

  defp validate_flash_size(flash_size) when flash_size > 0 and flash_size <= 0xFFFFFFFF,
    do: :ok

  defp validate_flash_size(_flash_size), do: {:error, :invalid_flash_size}

  defp validate_layout(partitions, flash_size) do
    partitions
    |> Enum.sort_by(& &1.offset)
    |> Enum.reduce_while(nil, fn partition, previous ->
      partition_end = partition.offset + partition.size

      cond do
        partition_end > flash_size ->
          {:halt, {:error, {:partition_exceeds_flash, partition.name}}}

        previous && previous.offset + previous.size > partition.offset ->
          {:halt, {:error, {:overlapping_partitions, previous.name, partition.name}}}

        true ->
          {:cont, partition}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      _partition -> :ok
    end
  end

  defp validate_last_partition(partition, partitions) do
    case Enum.find(partitions, &(&1.offset > partition.offset)) do
      nil -> :ok
      next_partition -> {:error, {:partition_not_last, partition.name, next_partition.name}}
    end
  end

  defp validate_expansion(partition, flash_size) do
    current_end = partition.offset + partition.size

    cond do
      partition.offset >= flash_size ->
        {:error, {:partition_exceeds_flash, partition.name}}

      current_end > flash_size ->
        {:error, {:partition_exceeds_flash, partition.name}}

      true ->
        :ok
    end
  end

  defp rebuild(records, target_entry_offset, new_size) do
    {iodata, _segment} =
      Enum.map_reduce(records, [], fn
        {:partition, %{entry_offset: ^target_entry_offset}, entry}, segment ->
          updated_entry = update_size(entry, new_size)
          {updated_entry, [updated_entry | segment]}

        {:partition, _partition, entry}, segment ->
          {entry, [entry | segment]}

        {:md5, _entry}, segment ->
          {@md5_prefix <> segment_digest(segment), []}

        {:tail, remaining}, segment ->
          {remaining, segment}
      end)

    IO.iodata_to_binary(iodata)
  end

  defp update_size(
         <<prefix::binary-size(8), _size::little-unsigned-32, suffix::binary>>,
         new_size
       ) do
    <<prefix::binary, new_size::little-unsigned-32, suffix::binary>>
  end

  defp segment_digest(segment) do
    data =
      segment
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    :crypto.hash(:md5, data)
  end

  defp decode_label(label) do
    label
    |> :binary.split(<<0>>, [:global])
    |> hd()
  end
end
