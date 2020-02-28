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
         install_prefix when install_prefix != nil <- System.get_env("ATOMVM_INSTALL_PREFIX"),
         avms_path = Path.join(install_prefix, "lib/AtomVM/ebin/"),
         :ok <- pack_deps(avms_path),
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
    avms_path
    |> File.ls!()
    |> Enum.map(fn file -> Path.join(avms_path, file) end)
    |> PackBEAM.make_avm("deps.avm")
  end

  defp pack_beams(beams_path, start_beam_file, out) do
    beams_path
    |> File.ls!()
    |> Enum.filter(fn file -> String.ends_with?(file, ".beam") end)
    |> List.delete(start_beam_file)
    |> List.insert_at(0, start_beam_file)
    |> Enum.map(fn file -> Path.join(Project.compile_path(), file) end)
    |> Enum.concat(["deps.avm"])
    |> PackBEAM.make_avm(out)
  end
end
