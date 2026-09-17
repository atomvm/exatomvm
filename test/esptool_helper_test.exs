defmodule ExAtomVM.EsptoolHelperTest do
  use ExUnit.Case, async: true

  alias ExAtomVM.EsptoolHelper

  test "installed_version/1 reads the version of the AtomVM build on a device" do
    device = %{
      "atomvm_installed" => true,
      "build_info" => ["nightly-0.7+20260915.02e1603", "atomvm-esp32", "v5.5.4"]
    }

    assert EsptoolHelper.installed_version(device) == "nightly-0.7+20260915.02e1603"

    assert EsptoolHelper.installed_version(%{"atomvm_installed" => false, "build_info" => ["x"]}) ==
             nil

    assert EsptoolHelper.installed_version(%{"atomvm_installed" => true, "build_info" => []}) ==
             nil
  end

  test "sanitize_string/1 keeps printable ASCII" do
    assert EsptoolHelper.sanitize_string(<<"v0.6.6-dirty", 195, 169, 0>>) == "v0.6.6-dirty"
    assert EsptoolHelper.sanitize_string(<<0, 1>>) == "<unreadable>"
    assert EsptoolHelper.sanitize_string(nil) == "<invalid>"
  end
end
