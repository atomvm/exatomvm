defmodule Mix.Tasks.Atomvm.MacroTracer do
  @moduledoc false

  @manifest_name "atomvm_call_origins"

  # --- Compiler Tracer API ---

  def manifest_path do
    Path.join(Mix.Project.manifest_path(), @manifest_name)
  end

  def start do
    if :ets.whereis(__MODULE__) == :undefined do
      :ets.new(__MODULE__, [:named_table, :public, :bag])
    else
      :ets.delete_all_objects(__MODULE__)
    end

    Code.put_compiler_option(:tracers, [__MODULE__ | Code.get_compiler_option(:tracers)])
  end

  def stop do
    tracers = Code.get_compiler_option(:tracers) -- [__MODULE__]
    Code.put_compiler_option(:tracers, tracers)
    save_manifest()

    if :ets.whereis(__MODULE__) != :undefined do
      :ets.delete(__MODULE__)
    end
  end

  def trace({:remote_macro, _meta, module, name, arity}, _env) do
    macro_info = {module, name, arity}
    stack = Process.get(:macro_stack, [])
    Process.put(:macro_stack, [macro_info | stack])
    :ok
  end

  def trace(:remote_macro_expansion, _env) do
    :ok
  end

  def trace({:remote_function, _meta, module, name, arity}, _env) do
    call = "#{Atom.to_string(module)}:#{name}/#{arity}"

    case Process.get(:macro_stack, []) do
      [] -> :ok
      [macro_info | _] -> :ets.insert(__MODULE__, {call, macro_info})
    end

    :ok
  end

  def trace(_event, _env), do: :ok

  defp save_manifest do
    if :ets.whereis(__MODULE__) != :undefined do
      data =
        __MODULE__
        |> :ets.tab2list()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      File.mkdir_p!(Path.dirname(manifest_path()))
      File.write!(manifest_path(), :erlang.term_to_binary(data))
    end
  end

  def load_manifest do
    case File.read(manifest_path()) do
      {:ok, binary} -> :erlang.binary_to_term(binary)
      {:error, _} -> %{}
    end
  end

  # --- Macro Source Finding API ---

  @doc """
  Finds the source locations of macros that generated the given calls.
  Combines results from compile-time tracer and BEAM scanning.
  Only returns entries for calls that have macro sources.
  """
  def find_sources(missing_calls, opts \\ []) do
    tracer_results = find_from_tracer(missing_calls, opts)
    beam_results = find_from_beams(missing_calls, opts)

    Map.merge(beam_results, tracer_results, fn _k, beam_locs, tracer_locs ->
      Enum.uniq(tracer_locs ++ beam_locs)
    end)
  end

  defp find_from_tracer(macro_calls, opts) do
    tracer_manifest = load_manifest()
    target_calls = Map.keys(macro_calls)
    source_fn = Keyword.get(opts, :source_fn, &default_module_source/1)

    Enum.reduce(target_calls, %{}, fn call, acc ->
      case Map.get(tracer_manifest, call) do
        nil ->
          acc

        origins ->
          locations =
            origins
            |> Enum.uniq()
            |> Enum.map(fn {mod, name, arity} ->
              "#{source_fn.(mod)} (#{name}/#{arity})"
            end)

          Map.put(acc, call, locations)
      end
    end)
  end

  defp find_from_beams(macro_calls, opts) do
    dep_beams = Keyword.get(opts, :dep_beams, Mix.Tasks.Atomvm.Packbeam.runtime_deps_beams())
    source_fn = Keyword.get(opts, :source_fn, &default_beam_source/1)
    target_calls = macro_calls |> Map.keys() |> MapSet.new()

    Enum.reduce(dep_beams, %{}, fn beam_path, acc ->
      beam_binary = File.read!(beam_path)
      source_file = source_fn.(beam_path)

      case :beam_disasm.file(beam_binary) do
        {:beam_file, _module_name, _exports, _, _, code} ->
          find_macros_with_calls(code, target_calls)
          |> Enum.reduce(acc, fn {macro_name, arity, used_calls}, inner_acc ->
            Enum.reduce(used_calls, inner_acc, fn call, call_acc ->
              location = "#{source_file} (#{format_macro_name(macro_name)}/#{arity - 1})"
              Map.update(call_acc, call, [location], &[location | &1])
            end)
          end)

        _ ->
          acc
      end
    end)
  end

  defp find_macros_with_calls(code, target_calls) do
    Enum.flat_map(code, fn {:function, func_name, arity, _, func_code} ->
      if macro_function?(func_name) do
        calls = extract_matching_calls(func_code, target_calls)

        if MapSet.size(calls) > 0 do
          [{func_name, arity, MapSet.to_list(calls)}]
        else
          []
        end
      else
        []
      end
    end)
  end

  defp macro_function?(func_name) do
    func_name |> Atom.to_string() |> String.starts_with?("MACRO-")
  end

  defp extract_matching_calls(func_code, target_calls) do
    Enum.reduce(func_code, MapSet.new(), fn instr, acc ->
      case extract_ext_call(instr) do
        nil -> acc
        call_str -> if MapSet.member?(target_calls, call_str), do: MapSet.put(acc, call_str), else: acc
      end
    end)
  end

  defp extract_ext_call({:call_ext, _, {:extfunc, mod, func, ar}}),
    do: "#{Atom.to_string(mod)}:#{Atom.to_string(func)}/#{ar}"

  defp extract_ext_call({:call_ext_last, _, {:extfunc, mod, func, ar}}),
    do: "#{Atom.to_string(mod)}:#{Atom.to_string(func)}/#{ar}"

  defp extract_ext_call({:call_ext_only, _, {:extfunc, mod, func, ar}}),
    do: "#{Atom.to_string(mod)}:#{Atom.to_string(func)}/#{ar}"

  defp extract_ext_call(_), do: nil

  defp format_macro_name(func_name) do
    func_name |> Atom.to_string() |> String.replace_prefix("MACRO-", "")
  end

  defp default_module_source(module) do
    case :code.which(module) do
      :non_existing -> inspect(module)
      beam_path when is_list(beam_path) -> default_beam_source(List.to_string(beam_path))
      beam_path -> default_beam_source(beam_path)
    end
  end

  defp default_beam_source(beam_path) do
    beam_binary = File.read!(beam_path)

    source =
      case :beam_lib.chunks(beam_binary, [:compile_info]) do
        {:ok, {_, [{:compile_info, info}]}} ->
          case Keyword.get(info, :source) do
            nil -> beam_path
            source -> List.to_string(source)
          end

        _ ->
          beam_path
      end

    Path.relative_to_cwd(source)
  end

  # --- Reporting ---

  @doc """
  Reports macro sources for missing calls if any were traced to macros.
  """
  def report_macro_sources(missing) do
    macro_sources = find_sources(missing)

    if map_size(macro_sources) > 0 do
      IO.puts("Note: The following appear to come from macros defined in dependencies:")
      print_sources(macro_sources)
      IO.puts("")
    end
  end

  defp print_sources(macro_sources) do
    macro_sources
    |> Enum.sort_by(fn {call, _sources} -> call end)
    |> Enum.each(fn {call, sources} ->
      unique_sources = sources |> Enum.uniq() |> Enum.sort()
      IO.puts("* #{call}")
      Enum.each(unique_sources, &IO.puts("    macro in: #{&1}"))
    end)
  end
end
