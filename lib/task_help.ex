defmodule ExAtomVM.TaskHelp do
  @moduledoc false

  @boards [{"esp32", "ESP32"}, {"stm32", "STM32"}, {"pico", "Raspberry Pi Pico"}]
  @pages Enum.map(@boards, fn {board, _title} -> "atomvm." <> board end)

  def overview(help) do
    Mix.shell().info(help)

    tasks = Enum.reject(tasks("atomvm."), fn {name, _doc} -> name in @pages end)
    width = width(tasks)

    for {board, title} <- @boards do
      list(title, Enum.filter(tasks, fn {name, _doc} -> board_of(name) == board end), width)
    end

    list("Any board", Enum.filter(tasks, fn {name, _doc} -> board_of(name) == nil end), width)
  end

  def board(help, board) do
    Mix.shell().info(help)

    tasks = tasks("atomvm.#{board}.")
    list("Tasks", tasks, width(tasks))
  end

  defp tasks(prefix) do
    found =
      for module <- Mix.Task.load_all(),
          name = Mix.Task.task_name(module),
          String.starts_with?(name, prefix),
          doc = Mix.Task.shortdoc(module) do
        {name, doc}
      end

    Enum.sort(found)
  end

  defp board_of(name) do
    case String.split(name, ".") do
      ["atomvm", board, _sub | _rest] -> if List.keymember?(@boards, board, 0), do: board
      _ -> nil
    end
  end

  defp width(tasks) do
    Enum.reduce(tasks, 0, fn {name, _doc}, widest -> max(String.length(name), widest) end)
  end

  defp list(_title, [], _width), do: :ok

  defp list(title, tasks, width) do
    Mix.shell().info("#{title}:")

    for {name, doc} <- tasks do
      Mix.shell().info("  mix #{String.pad_trailing(name, width)} # #{doc}")
    end

    Mix.shell().info("")
  end
end
