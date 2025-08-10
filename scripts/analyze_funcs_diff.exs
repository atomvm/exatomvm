#!/usr/bin/env elixir

defmodule FuncsDiffAnalyzer do
  @moduledoc """
  Analyzes git diff output for priv/funcs.txt to identify actual content changes.

  This script distinguishes between functions that are genuinely added/removed
  versus functions that are simply reordered due to sorting changes.
  It provides a mathematical consistency check between git diff statistics
  and actual content changes.
  """

  @funcs_txt_path "priv/funcs.txt"
  def run do
    case System.cmd("git", ["diff", @funcs_txt_path], stderr_to_stdout: true) do
      {output, 0} when output != "" -> output |> parse_and_analyze() |> display_results()
      {_, 0} -> IO.puts("\nNo changes detected")
      {error, _} -> IO.puts("Error: #{error}")
    end
  end

  defp parse_and_analyze(diff_output) do
    {added, removed} =
      diff_output
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn
        "+" <> line, {adds, removes} ->
          if String.starts_with?(line, "++"), do: {adds, removes}, else: {[line | adds], removes}

        "-" <> line, {adds, removes} ->
          if String.starts_with?(line, "--"), do: {adds, removes}, else: {adds, [line | removes]}

        _, acc ->
          acc
      end)

    added_set = MapSet.new(added)
    removed_set = MapSet.new(removed)
    reordered = MapSet.intersection(added_set, removed_set)

    {MapSet.difference(added_set, reordered) |> Enum.sort(),
     MapSet.difference(removed_set, reordered) |> Enum.sort(), length(added), length(removed)}
  end

  defp display_results({actual_added, actual_removed, total_added, total_removed}) do
    git_net = total_added - total_removed
    content_net = length(actual_added) - length(actual_removed)

    IO.puts("\nGit diff: +#{total_added} -#{total_removed} = #{git_net} net lines")

    IO.puts(
      "Content: +#{length(actual_added)} -#{length(actual_removed)} = #{content_net} net functions"
    )

    IO.puts(
      "Math check: #{if git_net == content_net, do: "✅ CONSISTENT", else: "❌ INCONSISTENT"}"
    )

    case {actual_added, actual_removed} do
      {[], []} ->
        IO.puts("\n🔄 All changes are due to reordering")

      {funcs, []} ->
        show_functions("📈 NEW", funcs)

      {[], funcs} ->
        show_functions("📉 REMOVED", funcs)

      {new_funcs, old_funcs} ->
        [show_functions("📈 NEW", new_funcs), show_functions("📉 REMOVED", old_funcs)]
    end
  end

  defp show_functions(label, funcs) do
    IO.puts("\n#{label} FUNCTIONS (#{length(funcs)}):")

    funcs
    |> Enum.each(&IO.puts("  #{if String.contains?(label, "NEW"), do: "+", else: "-"} #{&1}"))
  end
end

# Run the analysis
#FuncsDiffAnalyzer.run()
