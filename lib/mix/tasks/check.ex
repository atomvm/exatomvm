defmodule Mix.Tasks.Atomvm.Check do
  alias Mix.Project

  def run(args) do
    Mix.Tasks.Compile.run(args)

    beams_path = Project.compile_path()

    instructions_check = check_instructions(beams_path)
    ext_calls_check = check_ext_calls(beams_path)

    with :ok <- instructions_check,
         :ok <- ext_calls_check do
      {:ok, []}
    else
      _any -> exit({:shutdown, 1})
    end
  end

  defp extract_instructions({:beam_file, module_name, _exported_funcs, _, _, code}) do
    instructions =
      scan_instructions(code, fn
        {:bif, _func, _, args, _}, acc ->
          ["bif#{length(args)}" | acc]

        {:gc_bif, _func, _, _, args, _}, acc ->
          ["gc_bif#{length(args)}" | acc]

        {:init, _}, acc ->
          ["kill" | acc]

        {:test, :is_ne, _, _}, acc ->
          ["is_not_equal" | acc]

        {:test, :is_ne_exact, _, _}, acc ->
          ["is_not_eq_exact" | acc]

        {:test, :is_eq, _, _}, acc ->
          ["is_equal" | acc]

        {:test, test, _, _}, acc ->
          ["#{test}" | acc]

        instr, acc when is_tuple(instr) ->
          ["#{elem(instr, 0)}" | acc]

        instr, acc when is_atom(instr) ->
          ["#{instr}" | acc]
      end)

    {module_name, instructions}
  end

  defp extract_instructions(path) do
    files = list_beam_files(path)

    exported_by_mod =
      Enum.reduce(files, %{}, fn filename, acc ->
        file_path = Path.join(path, filename)

        {module_name, exported} =
          File.read!(file_path)
          |> :beam_disasm.file()
          |> extract_instructions()

        Map.put(acc, module_name, exported)
      end)

    exported_by_mod
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.into(MapSet.new())
  end

  defp extract_ext_calls({:beam_file, module_name, _, _, _, code}) do
    ext_calls =
      scan_instructions(code, fn
        {:call_ext, _, {:extfunc, module, extfunc, arity}}, acc ->
          [{module, extfunc, arity} | acc]

        {:call_ext_last, _, {:extfunc, module, extfunc, arity}}, acc ->
          [{module, extfunc, arity} | acc]

        {:call_ext_only, _, {:extfunc, module, extfunc, arity}}, acc ->
          [{module, extfunc, arity} | acc]

        {:bif, func, _, args, _}, acc ->
          [{:erlang, func, length(args)} | acc]

        {:gc_bif, func, _, _, args, _}, acc ->
          [{:erlang, func, length(args)} | acc]

        _, acc ->
          acc
      end)

    {module_name, ext_calls}
  end

  def extract_exported({:beam_file, module_name, exported_funcs, _, _, _code}) do
    funcs =
      Enum.map(exported_funcs, fn {func_name, arity, _} ->
        "#{Atom.to_string(module_name)}:#{func_name}/#{arity}"
      end)
      |> Enum.uniq()

    {module_name, funcs}
  end

  def extract_exported(files) when is_list(files) do
    exported_by_mod =
      Enum.reduce(files, %{}, fn file_path, acc ->
        {module_name, exported} =
          File.read!(file_path)
          |> :beam_disasm.file()
          |> extract_exported()

        Map.put(acc, module_name, exported)
      end)

    exported_by_mod
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.into(MapSet.new())
  end

  def extract_exported(path) do
    Mix.Tasks.Atomvm.Packbeam.beam_files(path)
    |> extract_exported()
  end

  defp extract_calls(path) do
    files = list_beam_files(path)

    calls_by_mod =
      Enum.reduce(files, %{}, fn filename, acc ->
        file_path = Path.join(path, filename)

        {module_name, ext_calls} =
          File.read!(file_path)
          |> :beam_disasm.file()
          |> extract_ext_calls()

        Map.put(acc, module_name, ext_calls)
      end)

    calls_by_mod
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(fn {m, f, a} -> "#{Atom.to_string(m)}:#{Atom.to_string(f)}/#{a}" end)
    |> Enum.into(MapSet.new())
  end

  defp check_ext_calls(beams_path) do
    calls_set = extract_calls(beams_path)
    runtime_deps_beams = Mix.Tasks.Atomvm.Packbeam.runtime_deps_beams()

    exported_calls_set =
      MapSet.union(extract_exported(beams_path), extract_exported(runtime_deps_beams))

    avail_funcs =
      Path.join(:code.priv_dir(:exatomvm), "funcs.txt")
      |> File.stream!()
      |> Stream.map(&String.replace(&1, "\n", ""))
      |> Enum.into(MapSet.new())
      |> MapSet.union(exported_calls_set)

    missing = MapSet.difference(calls_set, avail_funcs)

    if MapSet.size(missing) != 0 do
      IO.puts("error: following modules or functions are not available on AtomVM:")
      print_list(missing)
      IO.puts("")

      :error
    else
      :ok
    end
  end

  defp check_instructions(beams_path) do
    instructions_set = extract_instructions(beams_path)

    avail_instructions =
      Path.join(:code.priv_dir(:exatomvm), "instructions.txt")
      |> File.stream!()
      |> Stream.map(&String.replace(&1, "\n", ""))
      |> Enum.into(MapSet.new())

    missing_instructions = MapSet.difference(instructions_set, avail_instructions)

    if MapSet.size(missing_instructions) != 0 do
      IO.puts("error: following missing instructions are used:")
      print_list(missing_instructions)
      IO.puts("")

      :error
    else
      :ok
    end
  end

  defp print_list(enum) do
    enum
    |> Enum.to_list()
    |> Enum.map(fn s -> "* #{s}" end)
    |> Enum.join("\n")
    |> IO.puts()
  end

  defp list_beam_files(path) do
    path
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".beam"))
  end

  defp scan_instructions(code, fun) do
    Enum.map(code, fn {:function, _func_name, _, _, func_code} ->
      Enum.reduce(func_code, [], fun)
    end)
    |> List.flatten()
    |> Enum.uniq()
  end
end
