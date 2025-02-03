defmodule Mix.Tasks.Atomvm.Uf2create do
  use Mix.Task

  @shortdoc "Create uf2 files appropriate for pico devices from a packed .avm application file"

  @moduledoc """
  Create uf2 files appropriate for pico devices from a packed .avm application file,
  if the packed file does not exist the `atomvm.packbeam` task will be used to create the file (after compilation if necessary).

  > #### Info {: .info}
  >
  > Normally using this task manually is not required, it is called automatically by `atomvm.pico.flash` if a uf2 file has not already been created.

  ## Usage example

  Within your AtomVM mix project run

  `
  $ mix atomvm.uf2create
  `

  Or with optional flags (which will override the config in mix.exs)

  `
  $ mix atomvm.uf2create --app_start /some/path
  `

  ## Configuration

  ExAtomVM can be configured from the mix.ex file and supports the following settings for the
  `atomvm.uf2create` task.

    * `:app_start` - The flash address ,in hexademical format, to place the application, default `0x10180000`

  ## Command line options

  Properties in the mix.exs file may be over-ridden on the command line using long-style flags (prefixed by --) by the same name
  as the [supported properties](#module-configuration)

  For example, you can use the `--app_start` option to specify or override the `app_start` property.
  """

  alias Mix.Project
  alias Mix.Tasks.Atomvm.Packbeam
  # require :uf2tool

  def run(args) do
    config = Project.config()

    with {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:args, {:ok, options}} <- {:args, parse_args(args)},
         {:pack, {:ok, _}} <- {:pack, Packbeam.run(args)} do
      app_start =
        parse_addr(
          Keyword.get(
            avm_config,
            :app_start,
            Map.get(options, :app_start, System.get_env("ATOMVM_PICO_APP_START", "0x10180000"))
          )
        )

      family_id =
        validate_fam(
          Keyword.get(
            avm_config,
            :family_id,
            Map.get(options, :family_id, System.get_env("ATOMVM_PICO_UF2_FAMILY", "rp2040"))
          )
        )

      :ok = :uf2tool.uf2create("#{config[:app]}.uf2", family_id, app_start, "#{config[:app]}.avm")
      IO.puts("Created #{config[:app]}.uf2")
    else
      {:atomvm, :error} ->
        IO.puts("error: missing AtomVM project config.")
        exit({:shutdown, 1})

      {:args, :error} ->
        IO.puts("Syntax: ")
        exit({:shutdown, 1})

      {:pack, _} ->
        IO.puts("error: failed PackBEAM, uf2 file will not be created.")
        exit({:shutdown, 1})
    end
  end

  defp parse_args(args) do
    parse_args(args, %{})
  end

  defp parse_args([], accum) do
    {:ok, accum}
  end

  defp parse_args([<<"--app_start">>, app_start | t], accum) do
    parse_args(t, Map.put(accum, :app_start, app_start))
  end

  defp parse_args([<<"--family_id">>, family_id | t], accum) do
    parse_args(t, Map.put(accum, :family_id, family_id))
  end

  defp parse_args([_ | t], accum) do
    parse_args(t, accum)
  end

  defp parse_addr("0x" <> addrhex) do
    {address, ""} = Integer.parse(addrhex, 16)
    address
  end

  defp parse_addr("16#" <> addrhex) do
    {address, ""} = Integer.parse(addrhex, 16)
    address
  end

  defp parse_addr(addrdec) do
    {address, ""} = Integer.parse(addrdec)
    address
  end

  defp validate_fam(family) do
    case family do
      "rp2040" ->
        :rp2040

      ":rp2040" ->
        :rp2040

      :rp2040 ->
        :rp2040

      "rp2035" ->
        :data

      ":rp2035" ->
        :data

      :rp2035 ->
        :data

      "data" ->
        :data

      ":data" ->
        :data

      :data ->
        :data

      "universal" ->
        :universal

      ":universal" ->
        :universal

      :universal ->
        :universal

      unsupported ->
        IO.puts("Unsupported 'family_id' #{unsupported}")
        exit({:shutdown, 1})
    end
  end
end
