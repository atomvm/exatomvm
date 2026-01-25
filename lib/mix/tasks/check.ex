defmodule Mix.Tasks.Atomvm.Check do
  use Mix.Task
  @shortdoc "Check application code for use of unsupported instructions"

  @moduledoc """
  Verifies that the functions and modules used are either part of the application source (or deps) or supported by AtomVM.

  The check will catch the use of any standard Elixir modules or functions used in the application that are not included in exavmlib.

  > #### Info {: .info}
  >
  > Note. The `Mix.Tasks.Atomvm.Packbeam` task depends on this one, so users will likely never need to use it directly.
  """

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

  defp extract_ext_calls({:beam_file, module_name, _, _, _, code}, source_file) do
    ext_calls =
      scan_instructions_with_location(code, module_name, fn
        {:call_ext, _, {:extfunc, module, extfunc, arity}}, {caller_mod, caller_func, caller_arity}, acc ->
          [{module, extfunc, arity, caller_mod, caller_func, caller_arity, source_file} | acc]

        {:call_ext_last, _, {:extfunc, module, extfunc, arity}}, {caller_mod, caller_func, caller_arity}, acc ->
          [{module, extfunc, arity, caller_mod, caller_func, caller_arity, source_file} | acc]

        {:call_ext_only, _, {:extfunc, module, extfunc, arity}}, {caller_mod, caller_func, caller_arity}, acc ->
          [{module, extfunc, arity, caller_mod, caller_func, caller_arity, source_file} | acc]

        {:bif, func, _, args, _}, {caller_mod, caller_func, caller_arity}, acc ->
          [{:erlang, func, length(args), caller_mod, caller_func, caller_arity, source_file} | acc]

        {:gc_bif, func, _, _, args, _}, {caller_mod, caller_func, caller_arity}, acc ->
          [{:erlang, func, length(args), caller_mod, caller_func, caller_arity, source_file} | acc]

        _, _location, acc ->
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

    Enum.reduce(files, %{}, fn filename, acc ->
      file_path = Path.join(path, filename)
      beam_binary = File.read!(file_path)
      source_file = get_source_file(file_path, beam_binary)

      {_module_name, ext_calls} =
        beam_binary
        |> :beam_disasm.file()
        |> extract_ext_calls(source_file)

      Enum.reduce(ext_calls, acc, fn {m, f, a, _caller_mod, caller_func, caller_arity, src}, inner_acc ->
        call_string = "#{Atom.to_string(m)}:#{Atom.to_string(f)}/#{a}"
        location = "#{src} (#{caller_func}/#{caller_arity})"
        Map.update(inner_acc, call_string, [location], fn sources -> [location | sources] end)
      end)
    end)
  end

  defp get_source_file(beam_path, beam_binary) do
    case :beam_lib.chunks(beam_binary, [:compile_info]) do
      {:ok, {_, [{:compile_info, info}]}} ->
        case Keyword.get(info, :source) do
          nil -> beam_path
          source -> List.to_string(source)
        end

      _ ->
        beam_path
    end
  end

  defp check_ext_calls(beams_path) do
    calls_map = extract_calls(beams_path)
    runtime_deps_beams = Mix.Tasks.Atomvm.Packbeam.runtime_deps_beams()

    exported_calls_set =
      MapSet.union(extract_exported(beams_path), extract_exported(runtime_deps_beams))

    avail_funcs =
      Path.join(:code.priv_dir(:exatomvm), "funcs.txt")
      |> File.stream!()
      |> Stream.map(&String.replace(&1, "\n", ""))
      |> Enum.into(MapSet.new())
      |> MapSet.union(exported_calls_set)

    missing =
      calls_map
      |> Map.filter(fn {call, _sources} -> not MapSet.member?(avail_funcs, call) end)

    if map_size(missing) != 0 do
      IO.puts("Warning: following modules or functions are not available on AtomVM:")
      print_list_with_sources(missing)
      IO.puts("")
      IO.puts("(Using them may not be supported; make sure ExAtomVM is fully updated.)")
      IO.puts("")

      :ok
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
      if MapSet.member?(missing_instructions, "elixir_erl_pass:parens_map_field/2") do
        IO.puts("""
        Error:
          using module.function() notation (with parentheses) to fetch
          map.field() is deprecated,
          you must remove the parentheses: map.field
        """)
      end

      IO.puts("Warning: following missing instructions are used:")
      print_list(missing_instructions)
      IO.puts("")
      IO.puts("(Using them may not be supported; make sure ExAtomVM is fully updated.)")
      IO.puts("")

      :ok
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

  defp print_list_with_sources(map) do
    map
    |> Enum.sort_by(fn {call, _sources} -> call end)
    |> Enum.map(fn {call, sources} ->
      unique_sources = sources |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")
      "* #{call}\n    in: #{unique_sources}"
    end)
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

  defp scan_instructions_with_location(code, module_name, fun) do
    Enum.flat_map(code, fn {:function, func_name, arity, _, func_code} ->
      location = {module_name, func_name, arity}
      Enum.reduce(func_code, [], fn instr, acc -> fun.(instr, location, acc) end)
    end)
  end
end
