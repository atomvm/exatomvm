defmodule ExAtomVM.Esp32CustomPartitionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ExAtomVM.Esp32CustomPartitions

  @moduletag :tmp_dir
  @table File.read!(Path.join(__DIR__, "fixtures/esp32_partitions.csv"))

  setup %{tmp_dir: tmp_dir} do
    platform_dir = Path.join(tmp_dir, "platform")
    File.mkdir_p!(platform_dir)
    source_path = Path.join(tmp_dir, "custom_partitions.csv")
    File.write!(source_path, @table)

    {:ok, selected} = Esp32CustomPartitions.load_custom_partitions(source_path)

    {:ok,
     platform_dir: platform_dir,
     source_path: source_path,
     dest_path: Path.join(platform_dir, "partitions-elixir.csv"),
     selected: selected}
  end

  test "loads the default CSV, or retains no selection if absent", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      assert {:ok, %{content: @table}} = Esp32CustomPartitions.load_custom_partitions(nil)
      File.rm!("custom_partitions.csv")
      assert {:ok, nil} = Esp32CustomPartitions.load_custom_partitions(nil)
      File.write!("custom_partitions.csv", @table)
      assert :stock = Esp32CustomPartitions.with_custom_partitions(tmp_dir, nil, fn -> :stock end)
    end)
  end

  test "rejects missing, empty, and directory paths", %{tmp_dir: tmp_dir} do
    assert {:error, "Partition table file does not exist: " <> _} =
             Esp32CustomPartitions.load_custom_partitions(Path.join(tmp_dir, "missing.csv"))

    path = Path.join(tmp_dir, "empty.csv")
    File.write!(path, "")
    assert {:error, "empty.csv is empty"} = Esp32CustomPartitions.load_custom_partitions(path)

    assert {:error, message} = Esp32CustomPartitions.load_custom_partitions(tmp_dir)
    assert message =~ "not a regular file"
  end

  test "loads custom CSV contents unchanged", %{source_path: path} do
    assert {:ok, %{content: @table}} = Esp32CustomPartitions.load_custom_partitions(path)

    table =
      @table
      |> String.replace("app, factory, 0x10000", "0x00, 0, 64K")
      |> String.replace("data, phy, 0x250000", "1, phy, 2424832")

    File.write!(path, table)
    assert {:ok, %{content: ^table}} = Esp32CustomPartitions.load_custom_partitions(path)
  end

  test "leaves main.avm offsets to AtomVM, including the JIT offset", %{source_path: path} do
    for offset <- ["0x300000", "0x280000", ""] do
      table =
        @table
        |> String.replace("0x250000", offset)
        |> String.replace("0x1B0000", "0x100000")

      File.write!(path, table)
      assert {:ok, %{content: ^table}} = Esp32CustomPartitions.load_custom_partitions(path)
    end
  end

  test "accepts A/B application partitions without main.avm", %{source_path: path} do
    table =
      String.replace(
        @table,
        "main.avm, data, phy, 0x250000, 0x1B0000,",
        "main_a.avm, data, phy, 0x250000, 0xD0000,\nmain_b.avm, data, phy, 0x320000, 0xE0000,"
      )

    refute table =~ "main.avm"
    File.write!(path, table)
    assert {:ok, %{content: ^table}} = Esp32CustomPartitions.load_custom_partitions(path)
  end

  test "passes arbitrary partition contents through without layout validation", ctx do
    for content <- [
          "slot_a, app, ota_0, 0x20000, 1M\nslot_b, app, ota_1, 0x120000, 1M\n",
          "storage, data, spiffs, , 512K\n",
          "# Name, Type, SubType, Offset, Size\n",
          "not a CSV"
        ] do
      File.write!(ctx.source_path, content)
      assert {:ok, selected} = Esp32CustomPartitions.load_custom_partitions(ctx.source_path)
      assert selected.content == content

      capture_io(fn ->
        assert :ok =
                 Esp32CustomPartitions.with_custom_partitions(ctx.platform_dir, selected, fn ->
                   assert File.read!(ctx.dest_path) == content
                   :ok
                 end)
      end)
    end
  end

  test "invalid selection fails before checking the AtomVM checkout", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        assert catch_exit(
                 Mix.Tasks.Atomvm.Esp32.Build.run([
                   "--partition-table",
                   Path.join(tmp_dir, "missing.csv"),
                   "--atomvm-path",
                   Path.join(tmp_dir, "missing-checkout")
                 ])
               ) == {:shutdown, 1}
      end)

    assert output =~ "Partition table file does not exist"
    refute output =~ "AtomVM path does not exist"
  end

  test "restores bytes and mode with read-only and executable sources, even on callback failure",
       ctx do
    for mode <- [0o444, 0o755], outcome <- [:ok, :error, :raise] do
      File.chmod!(ctx.source_path, mode)
      File.write!(ctx.dest_path, "original table")
      File.chmod!(ctx.dest_path, 0o644)
      {:ok, selected} = Esp32CustomPartitions.load_custom_partitions(ctx.source_path)

      callback = fn ->
        assert File.read!(ctx.dest_path) == @table
        assert Bitwise.band(File.stat!(ctx.dest_path).mode, 0o777) == 0o644

        case outcome do
          :raise -> raise "build failed"
          :error -> {:error, "build failed"}
          :ok -> :ok
        end
      end

      capture_io(fn ->
        if outcome == :raise do
          assert_raise RuntimeError, "build failed", fn ->
            Esp32CustomPartitions.with_custom_partitions(ctx.platform_dir, selected, callback)
          end
        else
          expected = if outcome == :ok, do: :ok, else: {:error, "build failed"}

          assert Esp32CustomPartitions.with_custom_partitions(
                   ctx.platform_dir,
                   selected,
                   callback
                 ) == expected
        end
      end)

      assert File.read!(ctx.dest_path) == "original table"
      assert Bitwise.band(File.stat!(ctx.dest_path).mode, 0o777) == 0o644
    end
  end

  test "removes the temporary destination when originally absent", ctx do
    capture_io(fn ->
      assert :ok =
               Esp32CustomPartitions.with_custom_partitions(ctx.platform_dir, ctx.selected, fn ->
                 assert File.read!(ctx.dest_path) == @table
                 :ok
               end)
    end)

    refute File.exists?(ctx.dest_path)
  end

  test "rejects a directory or dangling symlink destination without changing it", ctx do
    File.mkdir!(ctx.dest_path)

    assert {:error, _} =
             Esp32CustomPartitions.with_custom_partitions(ctx.platform_dir, ctx.selected, fn ->
               flunk("must not build")
             end)

    assert File.dir?(ctx.dest_path)
    File.rmdir!(ctx.dest_path)

    target = Path.join(ctx.tmp_dir, "missing-target")
    File.ln_s!(target, ctx.dest_path)

    assert {:error, _} =
             Esp32CustomPartitions.with_custom_partitions(ctx.platform_dir, ctx.selected, fn ->
               flunk("must not build")
             end)

    assert File.read_link!(ctx.dest_path) == target
    refute File.exists?(target)
  end

  test "reuses the selected bytes for later chips after cleaning deletes the source", ctx do
    build_dir = Path.join(ctx.platform_dir, "build")
    File.mkdir_p!(build_dir)
    path = Path.join(build_dir, "custom.csv")
    File.write!(path, @table)
    File.write!(ctx.dest_path, "original table")
    {:ok, selected} = Esp32CustomPartitions.load_custom_partitions(path)

    capture_io(fn ->
      for _chip <- [:esp32, :esp32s3] do
        assert :ok =
                 Esp32CustomPartitions.with_custom_partitions(ctx.platform_dir, selected, fn ->
                   File.rm_rf!(build_dir)
                   assert File.read!(ctx.dest_path) == @table
                   :ok
                 end)

        assert File.read!(ctx.dest_path) == "original table"
      end
    end)
  end

  test "supports selecting the destination itself", ctx do
    File.write!(ctx.dest_path, @table)
    {:ok, selected} = Esp32CustomPartitions.load_custom_partitions(ctx.dest_path)

    capture_io(fn ->
      assert :ok =
               Esp32CustomPartitions.with_custom_partitions(ctx.platform_dir, selected, fn ->
                 assert File.read!(ctx.dest_path) == @table
                 :ok
               end)
    end)

    assert File.read!(ctx.dest_path) == @table
  end

  test "restoration failure cannot report build success", ctx do
    File.write!(ctx.dest_path, "original table")

    capture_io(fn ->
      assert_raise File.Error, fn ->
        Esp32CustomPartitions.with_custom_partitions(ctx.platform_dir, ctx.selected, fn ->
          File.rm!(ctx.dest_path)
          File.mkdir!(ctx.dest_path)
          :ok
        end)
      end
    end)
  end
end
