defmodule ExAtomVM.Esp32BuildStagingTest do
  use ExUnit.Case, async: false

  alias ExAtomVM.Esp32BuildStaging

  @moduletag :tmp_dir

  test "snapshots and restores the contents of a regular file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "file")
    File.write!(path, "original")

    assert {:ok, {:content, "original"}} = Esp32BuildStaging.snapshot_file(path)
    File.write!(path, "staged")
    assert :ok = Esp32BuildStaging.restore_file(path, {:content, "original"})
    assert File.read!(path) == "original"
  end

  test "snapshots a missing file and removes it on restore", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "file")

    assert {:ok, :missing} = Esp32BuildStaging.snapshot_file(path)
    File.write!(path, "staged")
    assert :ok = Esp32BuildStaging.restore_file(path, :missing)
    refute File.exists?(path)
  end

  test "refuses directories and symlinks", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "dir")
    File.mkdir!(dir)
    assert {:error, :einval} = Esp32BuildStaging.snapshot_file(dir)

    link = Path.join(tmp_dir, "link")
    File.ln_s!(Path.join(tmp_dir, "missing-target"), link)
    assert {:error, :einval} = Esp32BuildStaging.snapshot_file(link)
  end

  test "reports a failed restore instead of raising", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "dir")
    File.mkdir!(path)

    assert {:error, reason} = Esp32BuildStaging.restore_file(path, :missing)
    assert reason in [:eisdir, :eperm]
    assert File.dir?(path)
  end
end
