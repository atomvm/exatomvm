defmodule ExAtomVM.SupportedApi do
  @moduledoc false

  # json is an OTP 27 module; without it the manifest is not read.
  @compile {:no_warn_undefined, :json}

  @env_var "ATOMVM_SUPPORTED_API"

  @type t :: %{
          version: String.t() | nil,
          source: :environment | :dependency,
          dir: String.t(),
          funcs: String.t(),
          instructions: String.t(),
          manifest: map() | nil
        }

  @doc """
  The supported API the project is checked against: the directory named by
  ATOMVM_SUPPORTED_API, else the one of the atomvm dependency.
  """
  @spec resolve() :: {:ok, t()} | :error
  def resolve do
    cond do
      dir = environment_dir() -> {:ok, from_dir(dir, :environment)}
      dir = dependency_dir() -> {:ok, from_dir(dir, :dependency, dependency_version())}
      true -> :error
    end
  end

  @spec describe(t()) :: String.t()
  def describe(%{version: nil}), do: "AtomVM"
  def describe(%{version: version}), do: "AtomVM #{version}"

  @spec describe_source(t() | :environment | :dependency) :: String.t()
  def describe_source(%{source: source}), do: describe_source(source)
  def describe_source(:environment), do: "the AtomVM build in #{@env_var}"
  def describe_source(:dependency), do: "the release of the atomvm dependency"

  @doc """
  The Erlang/OTP releases whose compiled modules the release loads, or `nil`
  when the manifest does not say.
  """
  @spec supported_erlang(t()) :: [integer()] | nil
  def supported_erlang(%{manifest: %{"supported_erlang" => versions}}) when is_list(versions),
    do: versions

  def supported_erlang(_api), do: nil

  @doc """
  The Elixir versions the release was tested with, as `"1.19"`, or `nil` when
  the manifest does not say.
  """
  @spec tested_elixir(t()) :: [String.t()] | nil
  def tested_elixir(%{manifest: %{"tested_elixir" => versions}}) when is_list(versions),
    do: versions

  def tested_elixir(_api), do: nil

  defp environment_dir do
    case System.get_env(@env_var) do
      "" -> nil
      dir -> dir
    end
  end

  defp from_dir(dir, source, version \\ nil) do
    funcs = Path.join(dir, "funcs.txt")
    instructions = Path.join(dir, "instructions.txt")

    Enum.each([funcs, instructions], fn path ->
      if not File.regular?(path) do
        Mix.raise("#{describe_source(source)} has no #{Path.basename(path)}: #{path}")
      end
    end)

    manifest = read_manifest(Path.join(dir, "manifest.json"))

    %{
      version: version || manifest_version(manifest),
      source: source,
      dir: dir,
      funcs: funcs,
      instructions: instructions,
      manifest: manifest
    }
  end

  defp manifest_version(%{"atomvm_version" => version}) when is_binary(version), do: version
  defp manifest_version(_manifest), do: nil

  defp dependency_dir do
    with :ok <- load_dependency(),
         dir when is_list(dir) <- :code.priv_dir(:atomvm) do
      to_string(dir)
    else
      _ -> nil
    end
  end

  defp dependency_version do
    case Application.spec(:atomvm, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  # The package has no modules, so the application is loaded by hand before
  # its version and its priv directory can be read.
  defp load_dependency do
    case Application.load(:atomvm) do
      :ok -> :ok
      {:error, {:already_loaded, :atomvm}} -> :ok
      error -> error
    end
  end

  defp read_manifest(path) do
    with true <- Code.ensure_loaded?(:json),
         {:ok, contents} <- File.read(path),
         %{} = manifest <- :json.decode(contents) do
      manifest
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
