#!/usr/bin/env elixir

Code.require_file("analyze_funcs_diff.exs", __DIR__)
defmodule AllFuncsUpdater do
  @moduledoc """
  Script to update priv/funcs.txt with all available functions from AtomVM sources.
  By default, assumes AtomVM is in the same parent directory as ExAtomVM and that
  AtomVM has been built in the AtomVM/build directory.

  Usage:
    elixir scripts/update_all_funcs.exs [atomvm_path]

  If atomvm_path is not provided, defaults to "../AtomVM".

  Updates priv/funcs.txt with all available functions from AtomVM sources.

  This script extracts functions from three sources:
  1. NIFs from nifs.gperf file
  2. Erlang beam files from eavmlib
  3. Elixir beam files from exavmlib

  Functions ending with '_nif' are filtered out as they are internal
  implementation details. The final list is sorted with Erlang functions
  first, followed by Elixir functions.
  """
  @default_atomvm_path "../AtomVM"
  @nifs_gperf_path "src/libAtomVM/nifs.gperf"
  @estdlib_beam_path  "build/libs/estdlib/src/beams"
  @erlang_beam_path  "build/libs/eavmlib/src/beams"
  @elixir_beam_path  "build/libs/exavmlib/lib/beams"
  @funcs_txt_path "priv/funcs.txt"

  def default_atomvm_path, do: @default_atomvm_path

  def run(atomvm_path \\ @default_atomvm_path) do
    IO.puts("Updating #{@funcs_txt_path}...")
    IO.puts("Using AtomVM path: #{atomvm_path}")

    try do
      nifs = extract_nifs(atomvm_path)
      beams = extract_beams(atomvm_path)

      all_funcs = (read_current() ++ nifs ++ beams)
                  |> Enum.uniq()
                  |> sort_erlang_first()

      File.write!(@funcs_txt_path, Enum.join(all_funcs, "\n") <> "\n")
      IO.puts("Total: #{length(all_funcs)} (nifs: #{length(nifs)}, beams: #{length(beams)})")
    rescue
      e in File.Error ->
        IO.puts("File error: #{e.reason} - #{e.path}")
        System.halt(1)
      e ->
        IO.puts("Unexpected error: #{inspect(e)}")
        System.halt(1)
    end
  end

  defp read_current do
    if File.exists?(@funcs_txt_path) do
      @funcs_txt_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.contains?(&1, "_nif/"))
    else
      []
    end
  end

  defp extract_nifs(atomvm_path) do
    path = Path.join(atomvm_path, @nifs_gperf_path)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.filter(&(String.contains?(&1, ":") and Regex.match?(~r/\/[0-9]/, &1)))
      |> Stream.map(&(&1 |> String.split(",", parts: 2) |> hd() |> String.trim()))
      |> Stream.reject(&(String.contains?(&1, "_nif/") or &1 == ""))
      |> Enum.to_list()
    else
      []
    end
  end

  defp extract_beams(atomvm_path) do
    [@estdlib_beam_path, @erlang_beam_path, @elixir_beam_path]
    |> Enum.map(&Path.join(atomvm_path, &1))
    |> Enum.flat_map(&extract_from_dir/1)
    |> Enum.uniq()
  end

  defp extract_from_dir(path) do
    if File.exists?(path) do
      path
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".beam"))
      |> Enum.flat_map(&extract_from_beam(Path.join(path, &1)))
    else
      []
    end
  end

  defp extract_from_beam(beam_path) do
    case :beam_lib.chunks(String.to_charlist(beam_path), [:exports]) do
      {:ok, {module, [{:exports, exports}]}} ->
        module_name = Atom.to_string(module)
        exports |> Enum.map(fn {f, a} -> "#{module_name}:#{f}/#{a}" end) |> Enum.reject(&String.contains?(&1, "_nif/"))
      {:error, :beam_lib, {:file_error, _, reason}} ->
        IO.puts("Warning: Could not read beam file #{beam_path}: #{reason}")
        []
      _ ->
        IO.puts("Warning: Unexpected format in beam file #{beam_path}")
        []
    end
  end

  defp sort_erlang_first(funcs) do
    {elixir, erlang} = Enum.split_with(funcs, &String.starts_with?(&1, "Elixir."))
    Enum.sort(erlang) ++ Enum.sort(elixir)
  end
end

# Run the script
atomvm_path = case System.argv() do
  [path] -> path
  [] -> AllFuncsUpdater.default_atomvm_path()
  _ ->
    IO.puts("Usage: elixir scripts/update_all_funcs.exs [atomvm_path]")
    System.halt(1)
end

AllFuncsUpdater.run(atomvm_path)
FuncsDiffAnalyzer.run()
