defmodule Mix.Tasks.Atomvm.PackbeamTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Packbeam

  @tag :tmp_dir
  test "lists the beams of a directory, leaving the Mix tasks out", %{tmp_dir: dir} do
    for file <- [
          "Elixir.MyApp.beam",
          "Elixir.MyApp.Mix.Tasks.beam",
          "Elixir.Mix.Tasks.MyApp.Chore.beam",
          "Elixir.Mix.Tasks.Compile.Custom.beam",
          "my_app_helper.beam",
          "notes.txt"
        ] do
      File.write!(Path.join(dir, file), "")
    end

    assert Packbeam.beam_files(dir) |> Enum.map(&Path.basename/1) |> Enum.sort() ==
             ["Elixir.MyApp.Mix.Tasks.beam", "Elixir.MyApp.beam", "my_app_helper.beam"]

    assert Packbeam.beam_files(dir) |> Enum.all?(&String.starts_with?(&1, dir))
  end
end
