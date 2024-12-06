defmodule Mix.Tasks.Atomvm.Uf2create do
  use Mix.Task
  alias Mix.Project
  alias Mix.Tasks.Atomvm.Packbeam
  # require :uf2tool

  def run(args) do
    config = Project.config()

    with {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:args, {:ok, options}} <- {:args, parse_args(args)},
         {:pack, {:ok, _}} <- {:pack, Packbeam.run(args)} do
      app_start =
        parse_addr(Keyword.get(avm_config, :app_start, Map.get(options, :app_start, System.get_env("ATOMVM_PICO_APP_START", "0x10180000"))))
      family_id =
        validate_fam(Keyword.get(avm_config, :family_id, Map.get(options, :family_id, System.get_env("ATOMVM_PICO_UF2_FAMILY", :universal))))

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
      "rp2040" -> :rp2040
      ":rp2040" -> :rp2040
      :rp2040 -> :rp2040
      "rp2035_riscv" -> :rp2035_riscv
      ":rp2035_riscv" -> :rp2035_riscv
      :rp2035_riscv -> :rp2035_riscv
      "rp2035_arm_s" -> :rp2035_arm_s
      ":rp2035_arm_s" -> :rp2035_arm_s
      :rp2035_arm_s -> :rp2035_arm_s
      "rp2035_arm_ns" -> :rp2035_arm_ns
      ":rp2035_arm_ns" -> :rp2035_arm_ns
      :rp2035_arm_ns -> :rp2035_arm_ns
      "absolute" -> :absolute
      ":absolute" -> :absolute
      :universal -> :absolute
      "data" -> :data
      ":data" -> :data
      :data -> :data
      "universal" -> :universal
      ":universal" -> :universal
      :universal -> :universal
      unsupported ->
        IO.puts("Unsupported 'family_id' #{unsupported}")
        exit({:shutdown, 1})
    end
  end
end
