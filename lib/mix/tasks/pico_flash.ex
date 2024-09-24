defmodule Mix.Tasks.Atomvm.Pico.Flash do
  use Mix.Task
  alias Mix.Project
  alias Mix.Tasks.Atomvm.Uf2create

  def run(args) do
    config = Project.config()

    with {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:args, {:ok, options}} <- {:args, parse_args(args)},
         {:uf2, :ok} <- {:uf2, Uf2create.run(args)} do
      pico_path = 
        Map.get(options, :pico_path, Keyword.get(avm_config, :pico_path, System.get_env("ATOMVM_PICO_MOUNT_PATH", get_default_mount())))
      pico_reset =
        Map.get(options, :pico_reset, Keyword.get(avm_config, :pico_reset, System.get_env("ATOMVM_PICO_RESET_DEV", get_reset_base())))
      picotool =
        Map.get(options, :picotool, Keyword.get(avm_config, :picotool, System.get_env("ATOMVM_PICOTOOL_PATH", "#{:os.find_executable(~c"picotool")}")))

      do_flash(pico_path, pico_reset, picotool)
    else
      {:atomvm, :error} ->
        IO.puts("error: missing AtomVM project config.")
        exit({:shutdown, 1})

      {:args, :error} ->
        IO.puts("Syntax: ")
        exit({:shutdown, 1})

      {:uf2, _} ->
        IO.puts("error: failed to create uf2 file, target will not be flashed.")
        exit({:shutdown, 1})
    end
  end

  defp parse_args(args) do
    parse_args(args, %{})
  end

  defp parse_args([], accum) do
    {:ok, accum}
  end

  defp parse_args([<<"--pico_path">>, pico_path | t], accum) do
    parse_args(t, Map.put(accum, :pico_path, pico_path))
  end

  defp parse_args([<<"--pico_reset">>, pico_reset | t], accum) do
    parse_args(t, Map.put(accum, :pico_reset, pico_reset))
  end

  defp parse_args([<<"--picotool">>, picotool | t], accum) do
    parse_args(t, Map.put(accum, :picotool, picotool))
  end

  defp parse_args([_ | t], accum) do
    parse_args(t, accum)
  end

  defp get_default_mount() do
    case :os.type() do
      {_fam, :linux} -> "/run/media/#{:os.getenv(~c"USER")}/RPI-RP2"
      {_fam, :darwin} -> "/Volumes/RPI-RP2"
      _ -> ""
    end
  end

  defp wait_for_mount(mount, count) when count < 30 do
    case File.stat(mount) do
      {:ok, filestat} ->
        case Map.get(filestat, :type) do
          :directory ->
            :ok
          _ ->
            IO.puts("Object found at #{mount} is not a directory")
            exit({:shutdown, 1})
        end
      {:error, :enoent} ->
        Process.sleep(1000)
        wait_for_mount(mount, count + 1)
      error ->
        IO.puts("unexpected error: #{error} while checking pico mount path.")
        exit({:shutdown, 1})
    end
  end

  defp wait_for_mount(_, 30) do
    IO.puts("error: Pico not mounted after 30 seconds. giving up...")
    exit({:shutdown, 1})
  end

  defp check_pico_mount(mount) do
    case File.stat(<<"#{mount}">>) do
      {:ok, info} ->
        case Map.get(info, :type) do
          :directory ->
            :ok
          _ ->
            IO.puts("error: object at pico mount path not a directory. Abort!")
            exit({:shutdown, 1})
        end
      _ ->
        IO.puts("error: Pico not mounted. Abort!")
        exit({:shutdown, 1})
    end
  end

  defp get_stty_file_flag() do
    case :os.type() do
      {_fam, :linux} -> "-F"
      _ -> "-f"
    end
  end

  defp get_reset_base() do
    case :os.type() do
      {_fam, :linux} -> "/dev/ttyACM*"
      {_fam, :darwin} -> "/dev/cu.usbmodem14*"
      _ -> ""
    end
  end

  defp needs_reset(resetdev) do
    case Path.wildcard(resetdev) do
      [] ->
        false
      [device | _t] ->
        case File.stat(device) do
          {:ok, info} ->
            case Map.get(info, :type) do
              :device -> {true, device}
              _ -> false
            end
          _ ->
            false
        end
      _ ->
        false
    end
  end

  defp do_reset(resetdev, picotool) do
    flag = get_stty_file_flag()
    cmd_args = ["#{flag}", "#{resetdev}", "1200"]

    case System.cmd("stty", cmd_args) do
      {"", 0} ->
        # Pause to let the device settle
        Process.sleep(200)
      error ->
        case picotool do
          false ->
            IO.puts("Error: #{error}\nUnable to locate 'picotool', close the serial monitor before flashing, or install picotool for automatic disconnect and BOOTSEL mode.")
            exit({:shutdown, 1})
          _ ->
            IO.puts("Warning: #{error}\nFor faster flashing remember to disconnect serial monitor first.")
            reset_args = ["reboot", "-f", "-u"]
            IO.puts("Disconnecting serial monitor with `picotool #{:lists.join(" ", reset_args)}` in 5 seconds...")
            Process.sleep(5000)
            case :string.trim(System.cmd(picotool, reset_args)) do
              {status, 0} ->
                case status do
                  "The device was asked to reboot into BOOTSEL mode." ->
                    :ok
                  pt_error ->
                    IO.puts("Failed to prepare pico for flashing: #{pt_error}")
                    exit({:shutdown, 1})
                end
              _ ->
                IO.puts("Failed to prepare pico for flashing: #{error}")
            end
        end
    end
  end

  defp do_flash(pico_path, pico_reset, picotool) do
    case needs_reset(pico_reset) do
      false ->
        :ok
      {true, reset_port} ->
        do_reset(reset_port, picotool)
        IO.puts("Waiting for the device at path #{pico_path} to settle and mount...")
        wait_for_mount(pico_path, 0)
    end

    check_pico_mount(pico_path)
    _bytes = File.copy!("#{Project.config()[:app]}.uf2", "#{pico_path}/#{Project.config()[:app]}.uf2", :infinity)
    IO.puts("Successfully loaded #{Project.config()[:app]} to the pico device at #{pico_path}.")
  end
end
