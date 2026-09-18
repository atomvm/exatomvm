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

  def missing_config(app \\ Mix.Project.config()[:app]) do
    module = start_module(app)

    """
    error: missing AtomVM project config.

    💡 mix.exs needs an atomvm section naming the module AtomVM starts:

         def project do
           [
             app: :#{app},
             ...
             atomvm: [start: #{module}]
           ]
         end

       #{module} must define start/0, which AtomVM calls when the board boots:

         defmodule #{module} do
           def start do
             IO.puts("Hello")
           end
         end

       The steps that follow: mix atomvm
    """
  end

  def missing_start(app \\ Mix.Project.config()[:app]) do
    module = start_module(app)

    """
    error: missing startup module.

    💡 The atomvm section of mix.exs must name the module AtomVM starts:

         atomvm: [start: #{module}]

       #{module} must define start/0, which AtomVM calls when the board boots.
       The steps that follow: mix atomvm
    """
  end

  defp start_module(app), do: Macro.camelize(Atom.to_string(app))

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
