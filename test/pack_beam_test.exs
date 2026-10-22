defmodule ExAtomVM.PackBEAMTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ExAtomVM.PackBEAM

  @avm_header <<0x23, 0x21, 0x2F, 0x75, 0x73, 0x72, 0x2F, 0x62, 0x69, 0x6E, 0x2F, 0x65, 0x6E,
                0x76, 0x20, 0x41, 0x74, 0x6F, 0x6D, 0x56, 0x4D, 0x0A, 0x00, 0x00>>
  @normal_file_flag 4
  @allowed_beam_chunks ~w(AtU8 Code ExpT LocT ImpT LitU FunT StrT LitT avmN Type Recs)
  @sources %{
    pb_start: ~S"""
    -module(pb_start).
    -export([start/0]).
    start() -> pb_other:value().
    """,
    pb_other: ~S"""
    -module(pb_other).
    -export([start/0, value/0]).
    start() -> not_the_entrypoint.
    value() -> {literal, "with", #{a => map}, [1, 2, 3]}.
    """,
    pb_lib: ~S"""
    -module(pb_lib).
    -export([f/0]).
    f() -> ok.
    """
  }

  setup_all do
    dir =
      Path.join(System.tmp_dir!(), "exatomvm_packbeam_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "priv/sub"))
    on_exit(fn -> File.rm_rf!(dir) end)

    beams =
      for {module, source} <- @sources, into: %{} do
        src = Path.join(dir, "#{module}.erl")
        File.write!(src, source)
        {:ok, ^module} = :compile.file(to_charlist(src), [{:outdir, to_charlist(dir)}])
        {module, Path.join(dir, "#{module}.beam")}
      end

    File.write!(Path.join(dir, "priv/top.txt"), "hello from priv")
    File.write!(Path.join(dir, "priv/sub/nested.txt"), "nested")
    File.write!(Path.join(dir, "priv/ünïcödé.txt"), "non ascii name")

    %{dir: dir, beams: beams}
  end

  defp out(dir, name), do: Path.join(dir, name)

  defp elements(avm), do: :packbeam_api.list(to_charlist(avm))

  defp name(element), do: IO.iodata_to_binary(:packbeam_api.get_element_name(element))

  defp names(avm), do: avm |> elements() |> Enum.map(&name/1)

  defp element(avm, name), do: Enum.find(elements(avm), &(name(&1) == name))

  defp chunks(element) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(:packbeam_api.get_element_data(element))
    chunks
  end

  defp chunk_names(element),
    do: Enum.map(chunks(element), fn {name, _data} -> to_string(name) end)

  test "packs an application with start module, dependencies, priv files and AVM files",
       %{dir: dir, beams: beams} do
    deps_avm = out(dir, "deps.avm")
    priv_avm = out(dir, "priv.avm")
    app_avm = out(dir, "app.avm")

    assert :ok = PackBEAM.make_avm([{beams.pb_lib, :beam}], deps_avm)

    assert :ok =
             PackBEAM.make_avm(
               [
                 {Path.join(dir, "priv/top.txt"), [file: "my_app/priv/top.txt"]},
                 {Path.join(dir, "priv/sub/nested.txt"),
                  [file: "my_app/priv/sub/nested.txt", extra: :ignored]},
                 {Path.join(dir, "priv/ünïcödé.txt"), [file: "my_app/priv/ünïcödé.txt"]}
               ],
               priv_avm
             )

    assert :ok =
             PackBEAM.make_avm(
               [
                 {beams.pb_other, :beam},
                 {beams.pb_start, :beam_start},
                 # duplicated inputs are packed once
                 {beams.pb_other, :beam},
                 {deps_avm, :avm},
                 {priv_avm, :avm}
               ],
               app_avm
             )

    assert <<@avm_header, _::binary>> = File.read!(app_avm)

    assert names(app_avm) == [
             "pb_start.beam",
             "pb_other.beam",
             "pb_lib.beam",
             "my_app/priv/top.txt",
             "my_app/priv/sub/nested.txt",
             "my_app/priv/ünïcödé.txt"
           ]

    # pb_other exports start/0 too
    for element <- elements(app_avm) do
      name = name(element)
      assert :packbeam_api.is_entrypoint(element) == (name == "pb_start.beam")
      assert :packbeam_api.is_beam(element) == String.ends_with?(name, ".beam")
    end

    for name <- ["pb_start.beam", "pb_other.beam", "pb_lib.beam"] do
      chunks = chunk_names(element(app_avm, name))
      assert chunks -- @allowed_beam_chunks == []
      refute "Line" in chunks
    end

    top = element(app_avm, "my_app/priv/top.txt")
    assert :proplists.get_value(:flags, top) == @normal_file_flag
    assert <<15::32, "hello from priv", 0>> = :packbeam_api.get_element_data(top)

    assert <<14::32, "non ascii name", 0, 0>> =
             :packbeam_api.get_element_data(element(app_avm, "my_app/priv/ünïcödé.txt"))
  end

  test "compressed literal tables are uncompressed into LitU chunks", %{dir: dir, beams: beams} do
    {:ok, :pb_other, chunks} = :beam_lib.all_chunks(File.read!(beams.pb_other))

    literals =
      case List.keyfind(chunks, ~c"LitT", 0) do
        {_, <<0::32, uncompressed::binary>>} -> uncompressed
        {_, <<_size::32, compressed::binary>>} -> :zlib.uncompress(compressed)
      end

    forms = [
      # OTP 27 and earlier
      {:compressed, <<byte_size(literals)::32, :zlib.compress(literals)::binary>>,
       {~c"LitU", literals}},
      # OTP 28 and later
      {:uncompressed, <<0::32, literals::binary>>, {~c"LitT", <<0::32, literals::binary>>}}
    ]

    for {form, litt, expected} <- forms do
      {:ok, beam} = :beam_lib.build_module(List.keyreplace(chunks, ~c"LitT", 0, {~c"LitT", litt}))
      path = Path.join(dir, "#{form}/pb_other.beam")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, beam)

      avm = out(dir, "#{form}.avm")
      assert :ok = PackBEAM.make_avm([{path, :beam_start}], avm)

      packed = chunks(element(avm, "pb_other.beam"))
      literal_chunks = Enum.filter(packed, fn {name, _data} -> name in [~c"LitT", ~c"LitU"] end)
      assert literal_chunks == [expected]
    end
  end

  test "AVM files without start module have no entrypoint, even when including one",
       %{dir: dir, beams: beams} do
    app_avm = out(dir, "runnable.avm")
    lib_avm = out(dir, "lib.avm")

    assert :ok = PackBEAM.make_avm([{beams.pb_start, :beam_start}], app_avm)
    assert :ok = PackBEAM.make_avm([{beams.pb_other, :beam}, {app_avm, :avm}], lib_avm)

    assert names(lib_avm) == ["pb_other.beam", "pb_start.beam"]
    refute Enum.any?(elements(lib_avm), &:packbeam_api.is_entrypoint/1)
    assert Enum.all?(elements(lib_avm), &:packbeam_api.is_beam/1)

    assert :ok = PackBEAM.make_avm([], out(dir, "empty.avm"))
    assert names(out(dir, "empty.avm")) == []
  end

  test "include_lines keeps the Line chunk", %{dir: dir, beams: beams} do
    avm = out(dir, "lines.avm")
    assert :ok = PackBEAM.make_avm([{beams.pb_start, :beam_start}], avm, include_lines: true)
    assert "Line" in chunk_names(element(avm, "pb_start.beam"))
  end

  test "reports missing files", %{dir: dir} do
    missing = Path.join(dir, "Elixir.Missing.beam")

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, :enoent} = PackBEAM.make_avm([{missing, :beam_start}], out(dir, "x.avm"))
      end)

    assert stderr =~ "Cannot find #{missing}. Wrong module name?"
    refute File.exists?(out(dir, "x.avm"))
  end

  test "reports invalid inputs", %{dir: dir, beams: beams} do
    capture_io(:stderr, fn ->
      assert {:error, {:multiple_start_modules, _}} =
               PackBEAM.make_avm(
                 [{beams.pb_start, :beam_start}, {beams.pb_other, :beam_start}],
                 out(dir, "x.avm")
               )

      assert {:error, {:unsupported_input, _, :beam}} =
               PackBEAM.make_avm([{Path.join(dir, "priv/top.txt"), :beam}], out(dir, "x.avm"))

      assert {:error, {:unsupported_input, _, :nope}} =
               PackBEAM.make_avm([{beams.pb_start, :nope}], out(dir, "x.avm"))

      assert {:error, {:unsupported_input, _, [name: "x"]}} =
               PackBEAM.make_avm(
                 [{Path.join(dir, "priv/top.txt"), [name: "x"]}],
                 out(dir, "x.avm")
               )

      assert {:error, _} =
               PackBEAM.make_avm([{Path.join(dir, "priv/top.txt"), :avm}], out(dir, "x.avm"))
    end)

    refute File.exists?(out(dir, "x.avm"))
  end

  test "reports errors raised while packing", %{dir: dir} do
    bad_beam = Path.join(dir, "bad.beam")
    File.write!(bad_beam, "this is not a BEAM file")

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, _} = PackBEAM.make_avm([{bad_beam, :beam}], out(dir, "x.avm"))
      end)

    assert stderr =~ "Cannot pack #{out(dir, "x.avm")}"
    refute File.exists?(out(dir, "x.avm"))
  end
end
