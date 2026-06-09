defmodule ExAtomVM.Esp32ImageHeaderTest do
  use ExUnit.Case, async: true

  alias ExAtomVM.Esp32ImageHeader

  test "reads flash size without changing the frequency nibble" do
    assert {:ok, 0x20} = Esp32ImageHeader.flash_size_id(<<0xE9, 4, 2, 0x2F, 0, 0, 0, 0>>)
    assert {:ok, 0x400000} = Esp32ImageHeader.flash_size(<<0xE9, 4, 2, 0x2F>>)

    assert {:ok, 0x30} = Esp32ImageHeader.flash_size_id(<<0xE9, 4, 2, 0x3F, 0, 0, 0, 0>>)
    assert {:ok, 0x800000} = Esp32ImageHeader.flash_size(<<0xE9, 4, 2, 0x3F>>)

    assert {:ok, 0x40} = Esp32ImageHeader.flash_size_id(<<0xE9, 4, 2, 0x4F, 0, 0, 0, 0>>)
    assert {:ok, 0x1000000} = Esp32ImageHeader.flash_size(<<0xE9, 4, 2, 0x4F>>)

    assert {:ok, 0x50} = Esp32ImageHeader.flash_size_id(<<0xE9, 4, 2, 0x5F, 0, 0, 0, 0>>)
    assert {:ok, 0x2000000} = Esp32ImageHeader.flash_size(<<0xE9, 4, 2, 0x5F>>)
  end

  test "rejects invalid image headers" do
    assert {:error, :invalid_image_header} = Esp32ImageHeader.flash_size(<<0xFF, 0, 0, 0>>)
    assert {:error, :invalid_image_header} = Esp32ImageHeader.flash_size(<<0xE9, 0, 0>>)
  end
end
