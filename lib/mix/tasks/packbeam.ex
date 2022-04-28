defmodule Mix.Tasks.Atomvm.Packbeam do
  use Mix.Task
  alias ExAtomVM.PackBEAM
  alias Mix.Project
  alias Mix.Tasks.Atomvm.Check

  def run(args) do
    with {:check, {:ok, _}} <- {:check, Check.run(args)},
         config = Project.config(),
         {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:start, {:ok, start_module}} <- {:start, Keyword.fetch(avm_config, :start)},
         {:ok, avms_path} <- avm_deps_path(),
         :ok <- pack_deps(avms_path),
         :ok <- pack_priv(),
         start_beam_file = "#{Atom.to_string(start_module)}.beam",
         :ok <- pack_beams(Project.compile_path(), start_beam_file, "#{config[:app]}.avm") do
      {:ok, []}
    else
      {:check, _} ->
        IO.puts("error: failed check, .beam files will not be packed.")
        :error

      {:atomvm, :error} ->
        IO.puts("error: missing AtomVM project config.")
        :error

      {:start, :error} ->
        IO.puts("error: missing startup module.")
        :error

      nil ->
        IO.puts("error: ATOMVM_INSTALL_PREFIX env var is not set.")
        :error

      error ->
        IO.puts("error: unexpected error: #{inspect(error)}.")
        :error
    end
  end

  defp pack_deps(avms_path) do
    deps_beams =
      Mix.Dep.cached()
      |> runtime_deps()
      |> Enum.reduce([], fn path, acc -> beam_files(path) ++ acc end)
      |> Enum.map(fn beam_file -> {beam_file, :beam} end)

    deps_avms =
      avms_path
      |> File.ls!()
      |> Enum.map(fn file -> {Path.join(avms_path, file), :avm} end)

    PackBEAM.make_avm(deps_beams ++ deps_avms, "deps.avm")
  end

  defp beam_files(path) do
    for file <- File.ls!(path), String.ends_with?(file, ".beam") do
      Path.join(path, file)
    end
  end

  defp pack_priv() do
    priv_dir_path =
      Project.config()[:app]
      |> Application.app_dir("priv")

    packbeam_inputs =
      case File.exists?(priv_dir_path) do
        true ->
          prefix =
            Project.config()[:app]
            |> Atom.to_string()
            |> Path.join("priv")

          priv_dir_path
          |> File.ls!()
          |> Enum.map(fn file -> {file, [file: Path.join(prefix, file)]} end)
          |> Enum.map(fn {file, opts} -> {Path.join(priv_dir_path, file), opts} end)

        false ->
          []
      end

    PackBEAM.make_avm(packbeam_inputs, "priv.avm")
  end

  defp pack_beams(beams_path, start_beam_file, out) do
    beams_path
    |> File.ls!()
    |> Enum.filter(fn file -> String.ends_with?(file, ".beam") end)
    |> List.delete(start_beam_file)
    |> Enum.map(fn file -> {file, :beam} end)
    |> List.insert_at(0, {start_beam_file, :beam_start})
    |> Enum.map(fn {file, opts} -> {Path.join(Project.compile_path(), file), opts} end)
    |> Enum.concat([{"deps.avm", :avm}, {"priv.avm", :avm}])
    |> PackBEAM.make_avm(out)
  end

  defp avm_deps_path() do
    deps_path = Project.deps_path()

    with true <- String.ends_with?(deps_path, "/deps"),
         deps_len = String.length(deps_path),
         prj_path = String.slice(deps_path, 0, deps_len - 5),
         avm_deps_path = Path.join(prj_path, "/avm_deps"),
         true <- File.exists?(avm_deps_path) do
      {:ok, avm_deps_path}
    else
      _ ->
        with prefix when prefix != nil <- System.get_env("ATOMVM_INSTALL_PREFIX"),
             true <- File.exists?(prefix) do
          {:ok, Path.join(prefix, "lib/AtomVM/ebin/")}
        else
          _ ->
            {:error, :no_avm_deps_path}
        end
    end
  end

  def runtime_deps(deps) do
    Enum.reduce(deps, [], fn dep, acc ->
      if Keyword.get(dep.opts, :runtime, true) do
        ["#{dep.opts[:build]}/ebin" | runtime_deps(dep.deps) ++ acc]
      else
        []
      end
    end)
  end
end
