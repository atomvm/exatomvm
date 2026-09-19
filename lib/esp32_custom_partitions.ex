defmodule ExAtomVM.Esp32CustomPartitions do
  @moduledoc false

  alias ExAtomVM.Esp32BuildStaging

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

    case Esp32BuildStaging.snapshot_file(dest_path) do
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
          restore!(dest_path, original)
        end

      {:error, reason} ->
        {:error,
         "Failed to read existing #{@atomvm_elixir_partitions_csv}: #{:file.format_error(reason)}"}
    end
  end

  # A failed restoration leaves the AtomVM checkout modified, so it must raise
  # rather than let the build report success.
  defp restore!(path, snapshot) do
    case Esp32BuildStaging.restore_file(path, snapshot) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "restore", path: path
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
