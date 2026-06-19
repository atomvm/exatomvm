defmodule ExAtomVM.Esp32ImageHeader do
  @moduledoc false

  import Bitwise

  @image_magic 0xE9
  @flash_sizes %{
    0x00 => 1 * 1024 * 1024,
    0x10 => 2 * 1024 * 1024,
    0x20 => 4 * 1024 * 1024,
    0x30 => 8 * 1024 * 1024,
    0x40 => 16 * 1024 * 1024,
    0x50 => 32 * 1024 * 1024,
    0x60 => 64 * 1024 * 1024,
    0x70 => 128 * 1024 * 1024
  }

  def flash_size_id(<<@image_magic, _segments, _mode, size_frequency, _rest::binary>>) do
    {:ok, band(size_frequency, 0xF0)}
  end

  def flash_size_id(_image), do: {:error, :invalid_image_header}

  def flash_size(image) do
    with {:ok, size_id} <- flash_size_id(image),
         {:ok, size} <- Map.fetch(@flash_sizes, size_id) do
      {:ok, size}
    else
      :error -> {:error, :unsupported_flash_size}
      error -> error
    end
  end
end
