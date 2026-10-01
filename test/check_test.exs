defmodule Mix.Tasks.Atomvm.CheckTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Check

  @api %{
    version: "0.7.0-beta.0",
    source: :dependency,
    dir: "priv",
    funcs: "priv/funcs.txt",
    instructions: "priv/instructions.txt",
    manifest: nil
  }

  test "finds the external calls in tail position too" do
    [{_module, beam}] =
      Code.compile_string("""
      defmodule Mix.Tasks.Atomvm.CheckTest.Calls do
        def only(x), do: IO.puts(x)

        def last(x) do
          IO.inspect(x)
          Enum.reverse(x)
        end
      end
      """)

    {Mix.Tasks.Atomvm.CheckTest.Calls, calls} =
      beam |> :beam_disasm.file() |> Check.extract_ext_calls()

    for call <- [{IO, :puts, 1}, {IO, :inspect, 1}, {Enum, :reverse, 1}] do
      assert call in calls
    end
  end

  test "the atomvm dependency counts only when the project declares it" do
    exatomvm = {:exatomvm, github: "atomvm/exatomvm", runtime: false}

    assert Check.declared?([{:atomvm, "~> 0.7.0-alpha.1", runtime: false}])
    assert Check.declared?([exatomvm, {:atomvm, "~> 0.7.0-alpha.1"}])
    assert Check.declared?([{:atomvm, path: "../AtomVM/package"}])
    refute Check.declared?([exatomvm])
    refute Check.declared?([])
    refute Check.declared?(nil)
  end

  test "the warnings list every missing entry and name the release" do
    missing = MapSet.new(["Elixir.File:read!/1", "crypto:start/0"])

    for warning <- [
          Check.functions_warning(missing, @api),
          Check.instructions_warning(missing, @api)
        ] do
      assert String.printable?(warning)
      refute warning =~ ~r/[^\x00-\x7F]/
      assert warning =~ "0.7.0-beta.0"
      assert warning =~ "atomvm dependency"

      lines = String.split(warning, "\n")
      for entry <- missing, do: assert("* #{entry}" in lines)

      for line <- lines, not String.starts_with?(line, "* ") do
        assert String.length(line) <= 80, "a line of #{String.length(line)}: #{line}"
      end
    end
  end

  test "the OTP warning fires only for an OTP the manifest leaves out" do
    api = %{@api | manifest: %{"supported_erlang" => [26, 27, 28, 29]}}

    assert Check.otp_warning(api, 29) == nil
    assert Check.otp_warning(@api, 30) == nil
    assert Check.otp_warning(%{@api | manifest: %{}}, 30) == nil

    warning = Check.otp_warning(api, 30)
    assert warning =~ "30"
    assert warning =~ "0.7.0-beta.0"
    for otp <- 26..29, do: assert(warning =~ "#{otp}")
  end

  test "the Elixir line is added only for a version the release was not tested with" do
    api = %{@api | manifest: %{"tested_elixir" => ["1.17", "1.18", "1.19"]}}
    missing = MapSet.new(["x:y/0"])

    assert Check.elixir_note(api, "1.18.3") == nil
    assert Check.elixir_note(@api, "1.20.0-rc.6") == nil

    note = Check.elixir_note(api, "1.20.0-rc.6")
    assert note =~ "1.20"
    for elixir <- ["1.17", "1.18", "1.19"], do: assert(note =~ elixir)
    assert String.length(note) <= 80

    assert Check.functions_warning(missing, api, "1.20.0") =~ note
    refute Check.functions_warning(missing, api, "1.19.0") =~ "tested"
    refute Check.instructions_warning(missing, api) =~ "tested"
  end

  test "the warnings name the variable when it is the source" do
    api = %{@api | source: :environment, version: nil}
    warning = Check.functions_warning(MapSet.new(["x:y/0"]), api)

    assert warning =~ "ATOMVM_SUPPORTED_API"
    assert warning =~ "AtomVM"
    refute warning =~ "dependency"
  end
end
