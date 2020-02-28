defmodule ExAtomVM.PackBEAM do
  @allowed_chunks MapSet.new([
                    'AtU8',
                    'Code',
                    'ExpT',
                    'LocT',
                    'ImpT',
                    'LitU',
                    'FunT',
                    'StrT',
                    'LitT'
                  ])

  @avm_header <<0x23, 0x21, 0x2F, 0x75, 0x73, 0x72, 0x2F, 0x62, 0x69, 0x6E, 0x2F, 0x65, 0x6E,
                0x76, 0x20, 0x41, 0x74, 0x6F, 0x6D, 0x56, 0x4D, 0x0A, 0x00, 0x00>>

  defp uncompress_literals(chunks) do
    with {'LitT', litt} <- List.keyfind(chunks, 'LitT', 0),
         <<_header::binary-size(4), data::binary>> <- litt do
      litu = :zlib.uncompress(data)

      chunks
      |> List.keyreplace('LitT', 0, {'LitU', litu})
    else
      nil -> chunks
      _ -> :error
    end
  end

  defp strip(chunks) do
    Enum.filter(chunks, fn {chunk_name, _} ->
      MapSet.member?(@allowed_chunks, chunk_name)
    end)
  end

  defp transform(beam_bytes) do
    with {:ok, module_name, chunks} <- :beam_lib.all_chunks(beam_bytes),
         u_chunks = uncompress_literals(chunks),
         s_chunks = strip(u_chunks),
         {:ok, bytes} <- :beam_lib.build_module(s_chunks) do
      {:ok, module_name, bytes}
    end
  end

  defp section_header_size(module_name) do
    12 + byte_size(module_name) + 1
  end

  defp section_header(module_name, type, size) do
    reserved = 0

    flags =
      case type do
        :eof -> 0
        :beam_start -> 1
        :beam -> 2
      end

    <<size::32-big, flags::32-big, reserved::32-big, module_name::binary, 0>>
  end

  defp padding(size) do
    if rem(size, 4) != 0 do
      padding_size = 4 - rem(size, 4)
      {List.duplicate(0, padding_size), padding_size}
    else
      {[], 0}
    end
  end

  defp pack_module(module, opts) do
    with {:ok, beam_bytes} <- File.read(module),
         {:ok, module_atom, transformed_module} <- transform(beam_bytes) do
      module_name = "#{Atom.to_string(module_atom)}.beam"
      header_size = section_header_size(module_name)
      {header_padding, header_padding_size} = padding(header_size)
      {beam_padding, beam_padding_size} = padding(byte_size(transformed_module))

      size = header_size + header_padding_size + byte_size(transformed_module) + beam_padding_size

      header = section_header(module_name, opts, size)
      {:ok, [header, header_padding, transformed_module, beam_padding]}
    end
  end

  def extract_avm_content(avm_file) do
    with {:ok, avm_bytes} <- File.read(avm_file),
         <<@avm_header, without_header::binary>> <- avm_bytes do
      without_header_size = byte_size(without_header)
      end_header_size = byte_size(section_header("end", :eof, 0))

      {:ok, :binary.part(without_header, 0, without_header_size - end_header_size)}
    end
  end

  defp pack_file(file, opts) do
    cond do
      String.ends_with?(file, ".beam") ->
        pack_module(file, opts)

      String.ends_with?(file, ".avm") ->
        extract_avm_content(file)
    end
  end

  defp pack_files(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn {module, opts}, {:ok, acc} ->
      case pack_file(module, opts) do
        {:ok, res} -> {:cont, {:ok, [acc | res]}}
        error -> {:halt, error}
      end
    end)
  end

  defp make_avm(modules) do
    [startup | tail] = modules

    tail_modules_with_opts =
      Enum.map(tail, fn module ->
        {module, :beam}
      end)

    modules_with_opts = [{startup, :beam_start} | tail_modules_with_opts]

    with {:ok, packed} <- pack_files(modules_with_opts) do
      {:ok, [@avm_header, packed, section_header("end", :eof, 0)]}
    end
  end

  def make_avm(modules, out) do
    with {:ok, bytes} <- make_avm(modules) do
      File.write(out, bytes)
    end
  end
end
