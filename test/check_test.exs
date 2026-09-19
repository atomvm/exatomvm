defmodule Mix.Tasks.Atomvm.CheckTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Check

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
end
