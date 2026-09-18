defmodule Mix.Tasks.Atomvm.Esp32.FlashTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.Flash

  test "writes to the main.avm partition unless an address is pinned" do
    assert Flash.flash_target(%{}, start: MyApp) == {:partition, "main.avm"}
    assert Flash.flash_target(%{}, esp32_flash_offset: 0x210000) == {:offset, 0x210000}

    assert Flash.flash_target(%{flash_offset: 0x300000}, esp32_flash_offset: 0x210000) ==
             {:offset, 0x300000}

    assert_raise Mix.Error, ~r/^esp32_flash_offset must be an address/, fn ->
      Flash.flash_target(%{}, esp32_flash_offset: "0x250000")
    end
  end

  test "refuses an image bigger than its partition" do
    partition = %{name: "main.avm", offset: 0x250000, size: 0x100000}
    bigger = %{name: "app_b", offset: 0x350000, size: 0x200000}

    assert Flash.fits([partition, bigger], 0x100000) == :ok

    assert Flash.fits([bigger, partition], 0x100001) ==
             {:error, {:too_large, partition, 0x100001}}
  end

  test "points at atomvm.esp32.expand for a main.avm partition too small" do
    assert Flash.expand_hint() == """
           💡 mix atomvm.esp32.expand grows main.avm to the end of the flash, when it is
              the last partition, without touching anything else on the board
           """
  end

  test "parses --flash_offset as a hexadecimal address" do
    assert Flash.parse_args(["--flash_offset", "0x250000", "--port", "/dev/ttyACM0"]) ==
             {:ok, %{flash_offset: 0x250000, port: "/dev/ttyACM0"}}

    for value <- ["0x", "0x25zz", "250000", "auto"] do
      message = "--flash_offset expects an address such as 0x250000, got #{value}"

      assert_raise Mix.Error, message, fn ->
        Flash.parse_args(["--flash_offset", value])
      end
    end
  end
end
