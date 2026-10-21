defmodule ExAtomVM.PackBEAM do
  @moduledoc false

  def make_avm(inputs, out, opts \\ []) do
    inputs = Enum.uniq(inputs)

    with :ok <- validate_inputs(inputs),
         {:ok, start_module} <- start_module(inputs) do
      options = %{
        start_module: start_module || :undefined,
        # lib mode: modules exporting start/0 are not flagged as entrypoints
        lib: is_nil(start_module),
        include_lines: Keyword.get(opts, :include_lines, false)
      }

      create(out, inputs, options)
    end
  end

  defp create(out, inputs, options) do
    :packbeam_api.create(to_charlist(out), Enum.map(inputs, &to_packbeam_input/1), options)
  catch
    kind, reason ->
      IO.puts(:stderr, "Cannot pack #{out}: #{format_error(kind, reason)}")
      {:error, reason}
  end

  defp validate_inputs(inputs) do
    Enum.reduce_while(inputs, :ok, fn input, :ok ->
      case validate_input(input) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_input({path, type} = input) do
    with :ok <- validate_type(input) do
      validate_exists(path, type)
    end
  end

  defp validate_input(input) do
    IO.puts(:stderr, "Cannot pack #{inspect(input)}: expected a {path, type} tuple.")
    {:error, {:unsupported_input, input}}
  end

  defp validate_type({path, type}) when type in [:beam, :beam_start] do
    validate_extension(path, ".beam", type)
  end

  defp validate_type({path, :avm}) do
    validate_extension(path, ".avm", :avm)
  end

  defp validate_type({path, opts}) when is_list(opts) do
    case Keyword.fetch(opts, :file) do
      {:ok, name} when is_binary(name) or is_list(name) ->
        :ok

      _ ->
        IO.puts(:stderr, "Cannot pack #{path}: missing :file name in #{inspect(opts)}.")
        {:error, {:unsupported_input, path, opts}}
    end
  end

  defp validate_type({path, type}) do
    IO.puts(:stderr, "Cannot pack #{path}: unsupported input type #{inspect(type)}.")
    {:error, {:unsupported_input, path, type}}
  end

  defp validate_extension(path, extension, type) do
    if String.ends_with?(to_string(path), extension) do
      :ok
    else
      IO.puts(:stderr, "Cannot pack #{path}: #{inspect(type)} inputs must be #{extension} files.")
      {:error, {:unsupported_input, path, type}}
    end
  end

  defp validate_exists(path, type) do
    if File.exists?(path) do
      :ok
    else
      hint = if type in [:beam, :beam_start], do: " Wrong module name?", else: ""
      IO.puts(:stderr, "Cannot find #{path}.#{hint}")
      {:error, :enoent}
    end
  end

  defp start_module(inputs) do
    case for {path, :beam_start} <- inputs, do: path do
      [] ->
        {:ok, nil}

      [path] ->
        beam_module(path)

      paths ->
        IO.puts(
          :stderr,
          "Cannot pack: more than one start module given: #{Enum.join(paths, ", ")}."
        )

        {:error, {:multiple_start_modules, paths}}
    end
  end

  defp beam_module(path) do
    case :beam_lib.info(to_charlist(path)) do
      {:error, :beam_lib, reason} ->
        IO.puts(:stderr, "Cannot pack #{path}: #{:beam_lib.format_error(reason)}")
        {:error, reason}

      info ->
        {:ok, Keyword.fetch!(info, :module)}
    end
  end

  defp to_packbeam_input({path, opts}) when is_list(opts) do
    {to_charlist(path), element_name(Keyword.fetch!(opts, :file))}
  end

  defp to_packbeam_input({path, _type}), do: to_charlist(path)

  defp element_name(name), do: name |> to_string() |> :binary.bin_to_list()

  defp format_error(:throw, reason) when is_list(reason), do: IO.chardata_to_string(reason)
  defp format_error(:throw, reason), do: inspect(reason)
  defp format_error(kind, reason), do: Exception.format_banner(kind, reason)
end
