defmodule Mix.Tasks.Atomvm.Check do
  use Mix.Task
  @shortdoc "Check application code for use of unsupported instructions"

  @moduledoc """
  Verifies that the functions and the BEAM instructions the application uses
  are provided by the AtomVM release it targets, or by the application itself
  and its dependencies. Modules under `Mix.Tasks` are not checked, since
  `Mix.Tasks.Atomvm.Packbeam` does not pack them.

  The release is the one of the `atomvm` dependency of `mix.exs`, whose
  version is the AtomVM version:

      {:atomvm, "~> 0.7.0-beta.0", runtime: false}

  Without it the checks are skipped, a warning says what to add, and the
  application is packed anyway. `ATOMVM_SUPPORTED_API` names a directory with
  the same files instead, `funcs.txt` and `instructions.txt`, and wins over
  the dependency; a build of AtomVM from source writes one with:

      cmake --build build -t supported_api

  > #### Info {: .info}
  >
  > Note. The `Mix.Tasks.Atomvm.Packbeam` task depends on this one, so users will likely never need to use it directly.
  """

  alias ExAtomVM.SupportedApi
  alias ExAtomVM.TaskHelp
  alias Mix.Project

  # beam_disasm gives the float arithmetic opcodes and raise the same
  # {:bif, name, fail, args, dest} shape as bif0 to bif3. They are instructions,
  # listed in instructions.txt, and not calls to an erlang: function.
  @bif_shaped_instructions [:fadd, :fsub, :fmul, :fdiv, :fnegate, :raise]

  def run(args) do
    Mix.Tasks.Compile.run(args)

    beams_path = Project.compile_path()

    case SupportedApi.resolve() do
      {:ok, api} ->
        :ok = announce(api)
        :ok = check_instructions(beams_path, api)
        :ok = check_ext_calls(beams_path, api)

      :error ->
        IO.puts(TaskHelp.missing_dependency())
    end

    {:ok, []}
  end

  defp announce(%{source: :environment} = api) do
    IO.puts("Checking against #{SupportedApi.describe_source(api)}: #{api.dir}")
  end

  defp announce(%{source: :dependency}) do
    if not declared?(Project.config()[:deps]) do
      IO.puts(TaskHelp.missing_dependency())
    end

    :ok
  end

  @doc false
  def declared?(deps) do
    Enum.any?(List.wrap(deps), fn dep -> is_tuple(dep) and elem(dep, 0) == :atomvm end)
  end

  defp extract_instructions({:beam_file, module_name, _exported_funcs, _, _, code}) do
    instructions =
      scan_instructions(code, fn
        {:bif, func, _, _, _}, acc when func in @bif_shaped_instructions ->
          ["#{func}" | acc]

        {:bif, _func, _, args, _}, acc ->
          ["bif#{length(args)}" | acc]

        {:gc_bif, _func, _, _, args, _}, acc ->
          ["gc_bif#{length(args)}" | acc]

        {:init, _}, acc ->
          ["kill" | acc]

        instr, acc when is_tuple(instr) and elem(instr, 0) == :test ->
          ["#{test_name(elem(instr, 1))}" | acc]

        instr, acc when is_tuple(instr) ->
          ["#{elem(instr, 0)}" | acc]

        instr, acc when is_atom(instr) ->
          ["#{instr}" | acc]
      end)

    {module_name, instructions}
  end

  defp extract_instructions(path) do
    exported_by_mod =
      Enum.reduce(Mix.Tasks.Atomvm.Packbeam.beam_files(path), %{}, fn file_path, acc ->
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

  # A test tuple carries the instruction name second and comes in several sizes,
  # four for a plain comparison and up to six for the bit syntax ones. Three of
  # the comparisons beam_disasm spells differently from AtomVM's opcode table.
  defp test_name(:is_eq), do: :is_equal
  defp test_name(:is_ne), do: :is_not_equal
  defp test_name(:is_ne_exact), do: :is_not_eq_exact
  defp test_name(test), do: test

  @doc false
  def extract_ext_calls({:beam_file, module_name, _, _, _, code}) do
    ext_calls =
      scan_instructions(code, fn
        {:call_ext, _, {:extfunc, module, extfunc, arity}}, acc ->
          [{module, extfunc, arity} | acc]

        {:call_ext_last, _, {:extfunc, module, extfunc, arity}, _}, acc ->
          [{module, extfunc, arity} | acc]

        {:call_ext_only, _, {:extfunc, module, extfunc, arity}}, acc ->
          [{module, extfunc, arity} | acc]

        {:bif, func, _, args, _}, acc when func not in @bif_shaped_instructions ->
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
    calls_by_mod =
      Enum.reduce(Mix.Tasks.Atomvm.Packbeam.beam_files(path), %{}, fn file_path, acc ->
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

  defp check_ext_calls(beams_path, api) do
    calls_set = extract_calls(beams_path)
    runtime_deps_beams = Mix.Tasks.Atomvm.Packbeam.runtime_deps_beams()

    exported_calls_set =
      MapSet.union(extract_exported(beams_path), extract_exported(runtime_deps_beams))

    avail_funcs = MapSet.union(read_set(api.funcs), exported_calls_set)

    missing = MapSet.difference(calls_set, avail_funcs)

    if MapSet.size(missing) != 0 do
      IO.puts(functions_warning(missing, api))
    end

    :ok
  end

  defp check_instructions(beams_path, api) do
    instructions_set = extract_instructions(beams_path)

    missing_instructions = MapSet.difference(instructions_set, read_set(api.instructions))

    if MapSet.size(missing_instructions) != 0 do
      IO.puts(instructions_warning(missing_instructions, api))
    end

    :ok
  end

  defp read_set(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.replace(&1, "\n", ""))
    |> Enum.into(MapSet.new())
  end

  @doc false
  def functions_warning(missing, api) do
    warning("functions not available on #{SupportedApi.describe(api)}", missing, api)
  end

  @doc false
  def instructions_warning(missing, api) do
    warning("instructions not implemented by #{SupportedApi.describe(api)}", missing, api)
  end

  defp warning(what, missing, api) do
    """
    Warning: #{what}:
    #{missing |> Enum.sort() |> Enum.map_join("\n", &"* #{&1}")}

    (Checked against #{SupportedApi.describe_source(api)}.)
    """
  end

  defp scan_instructions(code, fun) do
    code
    |> Enum.reject(&macro_function?/1)
    |> Enum.map(fn {:function, _func_name, _, _, func_code} ->
      Enum.reduce(func_code, [], fun)
    end)
    |> List.flatten()
    |> Enum.uniq()
  end

  # A MACRO- function is the body of a macro or a guard: it runs in the compiler
  # on the build host and never on AtomVM, so what it calls and the instructions
  # it uses say nothing about the application.
  defp macro_function?({:function, name, _, _, _}) do
    String.starts_with?(Atom.to_string(name), "MACRO-")
  end
end
