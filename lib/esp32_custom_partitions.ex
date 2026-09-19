defmodule ExAtomVM.Esp32CustomPartitions do
  @moduledoc false

  @custom_partitions_csv "custom_partitions.csv"
  @atomvm_elixir_partitions_csv "partitions-elixir.csv"

  # Capture the selection before cloning or cleaning can remove the source.
  def load_custom_partitions(user_provided_path) do
    path = Path.expand(user_provided_path || @custom_partitions_csv)

    case File.lstat(path) do
      {:error, :enoent} when is_nil(user_provided_path) ->
        {:ok, nil}

      {:error, :enoent} ->
        {:error, "Partition table file does not exist: #{user_provided_path}"}

      _ ->
        with :ok <- validate_partition_file(path),
             {:ok, content} <- read_partition_file(path) do
          {:ok, %{path: path, content: content}}
        end
    end
  end

  def with_custom_partitions(_platform_dir, nil, fun), do: fun.()

  def with_custom_partitions(platform_dir, %{path: source_path, content: content}, fun) do
    dest_path = Path.join(platform_dir, @atomvm_elixir_partitions_csv)

    case snapshot_file(dest_path) do
      {:ok, original} ->
        source_filename = Path.basename(source_path)
        IO.puts("Copying #{source_filename} to #{dest_path} for this build...")

        try do
          # Writing bytes preserves the existing destination's permissions.
          case File.write(dest_path, content) do
            :ok ->
              fun.()

            {:error, reason} ->
              {:error, "Failed to copy #{source_filename}: #{:file.format_error(reason)}"}
          end
        after
          restore_file(dest_path, original)
        end

      {:error, reason} ->
        {:error,
         "Failed to read existing #{@atomvm_elixir_partitions_csv}: #{:file.format_error(reason)}"}
    end
  end

  def snapshot_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, content} -> {:ok, {:content, content}}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _stat} ->
        {:error, :einval}

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def restore_file(path, {:content, content}) do
    File.write!(path, content)
  end

  def restore_file(path, :missing) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "remove temporary partition table", path: path
    end
  end

  defp read_partition_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, "cannot read #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp validate_partition_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} ->
        {:error, "#{Path.basename(path)} is empty"}

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, _stat} ->
        {:error, "#{Path.basename(path)} exists but is not a regular file"}

      {:error, reason} ->
        {:error, "cannot read #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end
end
