defmodule ExAtomVM.SupportedApiTest do
  use ExUnit.Case

  alias ExAtomVM.SupportedApi

  @env_var "ATOMVM_SUPPORTED_API"

  @manifest """
  {
    "schema": 1,
    "atomvm_version": "0.7.0-beta.0",
    "supported_erlang": [26, 27, 28, 29],
    "tested_elixir": ["1.17", "1.18", "1.19"]
  }
  """

  @app """
  {application, atomvm, [
      {description, "a fake atomvm package"},
      {vsn, "0.7.0-beta.0"},
      {modules, []},
      {registered, []},
      {applications, [kernel, stdlib]},
      {env, [{supported_api, true}]}
  ]}.
  """

  setup do
    saved = System.get_env(@env_var)
    System.delete_env(@env_var)

    on_exit(fn ->
      if saved, do: System.put_env(@env_var, saved), else: System.delete_env(@env_var)
    end)
  end

  @tag :tmp_dir
  @tag :manifest
  test "resolves the directory named by the environment", %{tmp_dir: dir} do
    write_files(dir, @manifest)
    System.put_env(@env_var, dir)

    assert {:ok, api} = SupportedApi.resolve()
    assert api.source == :environment
    assert api.dir == dir
    assert api.version == "0.7.0-beta.0"
    assert File.regular?(api.funcs) and File.regular?(api.instructions)
    assert SupportedApi.supported_erlang(api) == [26, 27, 28, 29]
    assert SupportedApi.tested_elixir(api) == ["1.17", "1.18", "1.19"]
    assert SupportedApi.describe(api) =~ "0.7.0-beta.0"
  end

  @tag :tmp_dir
  test "resolves without a manifest, and then knows no version", %{tmp_dir: dir} do
    write_files(dir)
    System.put_env(@env_var, dir)

    assert {:ok, api} = SupportedApi.resolve()
    assert api.version == nil
    assert api.manifest == nil
    assert SupportedApi.supported_erlang(api) == nil
    assert SupportedApi.tested_elixir(api) == nil
    assert SupportedApi.describe(api) == "AtomVM"
  end

  @tag :tmp_dir
  test "a manifest that cannot be read is ignored", %{tmp_dir: dir} do
    write_files(dir, "{ not json")
    System.put_env(@env_var, dir)

    assert {:ok, api} = SupportedApi.resolve()
    assert api.manifest == nil
    assert api.version == nil
  end

  @tag :tmp_dir
  test "a directory without the data files is an error naming it", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "instructions.txt"), "call_ext\n")
    System.put_env(@env_var, dir)

    error = assert_raise Mix.Error, fn -> SupportedApi.resolve() end
    assert error.message =~ dir
    assert error.message =~ "funcs.txt"
    assert error.message =~ @env_var
  end

  @tag :tmp_dir
  test "resolves the atomvm dependency", %{tmp_dir: dir} do
    fake_dependency(dir, @manifest)

    assert {:ok, api} = SupportedApi.resolve()
    assert api.source == :dependency
    assert String.ends_with?(api.dir, "atomvm/priv")
    assert api.version == "0.7.0-beta.0"
    assert File.regular?(api.funcs) and File.regular?(api.instructions)
    assert SupportedApi.describe(api) =~ "0.7.0-beta.0"
  end

  @tag :tmp_dir
  test "the version of the dependency comes from its application", %{tmp_dir: dir} do
    fake_dependency(dir)

    assert {:ok, api} = SupportedApi.resolve()
    assert api.version == "0.7.0-beta.0"
    assert api.manifest == nil
  end

  @tag :tmp_dir
  test "resolves the dependency when its application is loaded already", %{tmp_dir: dir} do
    fake_dependency(dir)
    :ok = Application.load(:atomvm)

    assert {:ok, %{source: :dependency}} = SupportedApi.resolve()
  end

  @tag :tmp_dir
  test "the variable wins over the dependency", %{tmp_dir: dir} do
    fake_dependency(dir)
    override = Path.join(dir, "override")
    File.mkdir_p!(override)
    write_files(override)
    System.put_env(@env_var, override)

    assert {:ok, %{source: :environment, dir: ^override}} = SupportedApi.resolve()
  end

  @tag :tmp_dir
  test "an empty variable is ignored", %{tmp_dir: dir} do
    fake_dependency(dir)
    System.put_env(@env_var, "")

    assert {:ok, %{source: :dependency}} = SupportedApi.resolve()
  end

  test "a project naming no release resolves to nothing" do
    assert SupportedApi.resolve() == :error
  end

  defp write_files(dir, manifest \\ nil) do
    File.write!(Path.join(dir, "funcs.txt"), "erlang:display/1\nlists:seq/2\n")
    File.write!(Path.join(dir, "instructions.txt"), "call_ext\nreturn\n")
    if manifest, do: File.write!(Path.join(dir, "manifest.json"), manifest)
  end

  defp fake_dependency(dir, manifest \\ nil) do
    ebin = Path.join([dir, "atomvm", "ebin"])
    priv = Path.join([dir, "atomvm", "priv"])
    File.mkdir_p!(ebin)
    File.mkdir_p!(priv)
    File.write!(Path.join(ebin, "atomvm.app"), @app)
    write_files(priv, manifest)
    true = Code.prepend_path(ebin)

    on_exit(fn ->
      Application.unload(:atomvm)
      Code.delete_path(ebin)
    end)
  end
end
