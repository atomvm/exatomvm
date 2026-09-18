defmodule ExAtomVM.TaskHelpTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @pages [
    Mix.Tasks.Atomvm,
    Mix.Tasks.Atomvm.Esp32,
    Mix.Tasks.Atomvm.Stm32,
    Mix.Tasks.Atomvm.Pico
  ]

  test "every page is a printable text that fits a terminal" do
    for module <- @pages do
      text = Mix.Task.moduledoc(module)

      assert is_binary(text) and text != ""
      assert String.printable?(text)

      for line <- String.split(text, "\n") do
        assert String.length(line) <= 80,
               "#{inspect(module)} has a line of #{String.length(line)}"
      end
    end
  end

  test "the overview keeps the tasks of a board together" do
    tasks = listed_tasks(capture_io(fn -> Mix.Tasks.Atomvm.run([]) end))

    assert tasks != []

    for {_section, name} <- tasks do
      assert String.starts_with?(name, "atomvm.")
    end

    for board <- ~w(esp32 stm32 pico) do
      prefix = "atomvm.#{board}."
      sections = for {section, name} <- tasks, String.starts_with?(name, prefix), do: section

      assert sections != []
      assert [section] = Enum.uniq(sections)

      for {^section, name} <- tasks do
        assert String.starts_with?(name, prefix)
      end
    end
  end

  test "the overview leaves the page of a board out of the lists" do
    tasks = listed_tasks(capture_io(fn -> Mix.Tasks.Atomvm.run([]) end))

    names = for {_section, name} <- tasks, do: name

    for board <- ~w(esp32 stm32 pico) do
      refute "atomvm.#{board}" in names
    end
  end

  test "the page of a board lists the tasks of that board only" do
    tasks = listed_tasks(capture_io(fn -> Mix.Tasks.Atomvm.Esp32.run([]) end))

    assert tasks != []

    for {_section, name} <- tasks do
      assert String.starts_with?(name, "atomvm.esp32.")
    end
  end

  defp listed_tasks(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({0, []}, fn line, {section, listed} ->
      case Regex.run(~r/^  mix (\S+)/, line) do
        [_line, name] -> {section, [{section, name} | listed]}
        nil -> {if(line == "", do: section + 1, else: section), listed}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
