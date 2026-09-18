defmodule ExAtomVM.Esp32BuildStaging do
  @moduledoc false

  # Snapshots and restores files that a build stages into the AtomVM checkout,
  # so the checkout is left as it was found.
  #
  # A snapshot is `{:content, binary}` for a regular file or `:missing` when the
  # path does not exist. Directories, symlinks, and other non-regular files are
  # refused with `{:error, :einval}`, since writing to them would replace them
  # instead of restoring their contents.

  @doc false
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

  @doc false
  def restore_file(path, {:content, content}) do
    File.write(path, content)
  end

  @doc false
  def restore_file(path, :missing) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
