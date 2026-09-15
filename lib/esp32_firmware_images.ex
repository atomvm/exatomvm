defmodule ExAtomVM.Esp32FirmwareImages do
  @moduledoc false

  # Req is an optional dependency, see Mix.Tasks.Atomvm.Esp32.Install.
  @compile {:no_warn_undefined, Req}

  @atomvm_releases_url "https://api.github.com/repos/atomvm/atomvm/releases"
  @cache_dir "firmware_images"

  @chip_regex ~r/^esp32([a-z]\d+)?(_[a-z0-9]+)*$/
  @stable_regex ~r/^v\d+\.\d+\.\d+$/
  @version_regex ~r/^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)*$/
  @channel_regex ~r/^nightly(-[0-9A-Za-z.]+)+$/

  def release_api_url(nil), do: @atomvm_releases_url <> "/latest"

  def release_api_url(version) when is_binary(version) do
    @atomvm_releases_url <> "/tags/" <> URI.encode(version, &URI.char_unreserved?/1)
  end

  @doc """
  Parses an image name, `AtomVM-<chip>[-elixir][-<feature>...][-<version>]`,
  given bare, as a file name or as a path. The version is `v<x.y.z>` with an
  optional prerelease suffix, or a nightly channel such as `nightly-0.7`; a
  `+<suffix>` after it is the build stamp of a cached nightly.
  """
  def parse_name(name_or_path) do
    file = Path.basename(name_or_path)
    {stem, kind} = split_extension(file)

    with [atomvm, chip | rest] <- String.split(stem, "-"),
         true <- String.downcase(atomvm) == "atomvm",
         true <- Regex.match?(@chip_regex, chip),
         {flavor, version_tokens} = Enum.split_while(rest, &(not version_token?(&1))),
         {:ok, version, stamp} <- parse_version(version_tokens) do
      {:ok,
       %{
         name: hd(String.split(stem, "+", parts: 2)),
         file: if(kind, do: file),
         kind: kind,
         chip: chip,
         base_chip: hd(String.split(chip, "_")),
         elixir?: "elixir" in flavor,
         features: Enum.reject(flavor, &(&1 == "elixir")),
         version: version,
         channel: channel(version),
         stamp: stamp
       }}
    else
      _ -> {:error, {:unrecognized_name, file}}
    end
  end

  defp split_extension(file) do
    cond do
      String.ends_with?(file, ".img") -> {String.replace_suffix(file, ".img", ""), :img}
      String.ends_with?(file, ".zip") -> {String.replace_suffix(file, ".zip", ""), :zip}
      true -> {file, nil}
    end
  end

  defp version_token?("nightly"), do: true
  defp version_token?(token), do: Regex.match?(~r/^v\d/, token)

  defp parse_version([]), do: {:ok, nil, nil}

  defp parse_version(tokens) do
    {version, stamp} =
      case String.split(Enum.join(tokens, "-"), "+", parts: 2) do
        [version] -> {version, nil}
        [version, _suffix] = parts -> {version, Enum.join(parts, "+")}
      end

    if Regex.match?(@version_regex, version) or Regex.match?(@channel_regex, version) do
      {:ok, version, stamp}
    else
      :error
    end
  end

  defp channel(nil), do: :local
  defp channel("nightly" <> _), do: :nightly

  defp channel(version) do
    if Regex.match?(@stable_regex, version), do: :stable, else: :prerelease
  end

  @doc """
  The chip token used in image names for a chip family name reported by
  esptool, `"ESP32-C61"` giving `"esp32c61"`.
  """
  def chip_token(chip_family) do
    chip_family
    |> String.downcase()
    |> String.split(~r/[\s(]/, parts: 2)
    |> hd()
    |> String.replace("-", "")
  end

  @doc """
  The images among the assets of a GitHub release, as returned by the API.
  """
  def release_images(%{"tag_name" => tag} = release) do
    assets = release["assets"] || []

    sidecars =
      for %{"name" => name, "browser_download_url" => url} <- assets,
          String.ends_with?(name, ".sha256"),
          into: %{},
          do: {String.replace_suffix(name, ".sha256", ""), url}

    for %{"name" => name} = asset <- assets,
        String.ends_with?(name, [".img", ".zip"]),
        {:ok, image} <- [parse_name(name)] do
      Map.merge(image, %{
        source: :atomvm,
        tag: tag,
        url: asset["browser_download_url"],
        size: asset["size"],
        published_at: date(release["published_at"]),
        sha256: digest_from_asset(asset),
        sha256_url: sidecars[name],
        channel: release_channel(image.channel, release["prerelease"]),
        stamp: image.stamp || rolling_stamp(image, asset)
      })
    end
  end

  defp date(<<date::binary-size(10), _::binary>>), do: date
  defp date(_), do: nil

  defp release_channel(:stable, true), do: :prerelease
  defp release_channel(channel, _prerelease), do: channel

  # The assets of a rolling tag keep their names from one build to the next,
  # so a plain image there is told apart by the day it was uploaded. A bundle
  # carries its own build stamp, read once it is downloaded.
  defp rolling_stamp(%{channel: :nightly, kind: :img, version: version}, asset) do
    case date(asset["updated_at"]) do
      nil -> nil
      date -> version <> "+" <> String.replace(date, "-", "")
    end
  end

  defp rolling_stamp(_image, _asset), do: nil

  @doc """
  Fetches a release of the AtomVM repository, the latest stable one when the
  tag is nil.
  """
  def fetch_release(:atomvm, tag) do
    case fetch_json(release_api_url(tag)) do
      {:ok, release} -> {:ok, release}
      {:error, {:http, _url, {:status, 404}}} -> {:error, {:release_not_found, :atomvm, tag}}
      error -> error
    end
  end

  def fetch_json(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, url, {:status, status}}}
      {:error, exception} -> {:error, {:http, url, {:transport, Exception.message(exception)}}}
    end
  end

  defp fetch_binary(url) do
    case Req.get(url, raw: true) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, url, {:status, status}}}
      {:error, exception} -> {:error, {:http, url, {:transport, Exception.message(exception)}}}
    end
  end

  @doc """
  The directory downloaded images are kept in, at the root of the project so
  that a nightly build stays available once the factory has dropped it.
  """
  def cache_dir, do: Path.join(File.cwd!(), @cache_dir)

  @doc """
  The file name an image is cached under: its own for a release, its name
  plus the build stamp for a rolling tag, where names repeat.
  """
  def cached_file_name(%{stamp: stamp, name: name, kind: kind}) when is_binary(stamp) do
    [_version, suffix] = String.split(stamp, "+", parts: 2)
    "#{name}+#{suffix}.#{kind}"
  end

  def cached_file_name(%{file: file}) when is_binary(file), do: file

  @doc """
  The cached copies of the image called `name`, newest build first.
  """
  def find_cached(name) do
    dir = cache_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files |> cached_images(name) |> Enum.map(&Map.put(&1, :path, Path.join(dir, &1.file)))

      {:error, _reason} ->
        []
    end
  end

  def cached_images(files, name) do
    for file <- files,
        {:ok, %{name: ^name} = image} <- [parse_name(file)] do
      Map.merge(image, %{source: :cache, path: file})
    end
    |> Enum.sort_by(&{&1.stamp || "", &1.kind}, :desc)
  end

  @doc """
  Makes sure the image is in the cache, downloading and verifying it when it
  is not; `:log` is called with progress messages. Returns the image with its
  `:path`, and whether it was `:cached` already or `:downloaded` now.
  """
  def ensure_cached(image, opts \\ []) do
    log = Keyword.get(opts, :log, fn _message -> :ok end)
    path = Path.join(cache_dir(), cached_file_name(image))

    if File.exists?(path) do
      log.("Using cached #{Path.relative_to_cwd(path)}")
      {:ok, Map.put(image, :path, path), :cached}
    else
      log.("Downloading #{image.file}, may take a while...")

      with {:ok, data, checked} <- download_verified(image) do
        if checked == :unverified do
          log.(
            "Warning: no checksum is published for #{image.file}, the download was not verified"
          )
        end

        write_atomically(path, data)
        {:ok, Map.put(image, :path, path), :downloaded}
      end
    end
  end

  @doc """
  Downloads an image and checks its size and sha256, against the digest
  GitHub reports or the .sha256 file published next to it.
  """
  def download_verified(%{url: url, file: file} = image) do
    with {:ok, data} <- fetch_binary(url),
         :ok <- check_size(image, data),
         {:ok, expected} <- expected_sha256(image) do
      case expected do
        nil ->
          {:ok, data, :unverified}

        hex ->
          case verify_sha256(data, hex) do
            :ok ->
              {:ok, data, :verified}

            {:error, {:digest_mismatch, exp, actual}} ->
              {:error, {:digest_mismatch, file, exp, actual}}
          end
      end
    end
  end

  defp check_size(%{size: size, file: file}, data) when is_integer(size) do
    if byte_size(data) == size,
      do: :ok,
      else: {:error, {:size_mismatch, file, size, byte_size(data)}}
  end

  defp check_size(_image, _data), do: :ok

  defp expected_sha256(%{sha256: hex}) when is_binary(hex), do: {:ok, hex}

  defp expected_sha256(%{sha256_url: url, file: file}) when is_binary(url) do
    with {:ok, text} <- fetch_binary(url) do
      case Enum.find(parse_sha256_lines(text), fn {_hex, name} -> name == file end) do
        {hex, _name} -> {:ok, hex}
        nil -> {:ok, nil}
      end
    end
  end

  defp expected_sha256(_image), do: {:ok, nil}

  @doc """
  The `<sha256>  <name>` lines of a sha256sum file.
  """
  def parse_sha256_lines(text) do
    for line <- String.split(text, "\n"),
        [hex, name] <- [String.split(String.trim(line), ~r/\s+\*?/, parts: 2)],
        byte_size(hex) == 64 do
      {String.downcase(hex), name}
    end
  end

  def verify_sha256(data, expected) do
    actual = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    if actual == String.downcase(expected) do
      :ok
    else
      {:error, {:digest_mismatch, String.downcase(expected), actual}}
    end
  end

  @doc """
  Writes the file under a temporary name first, so that a failure never
  leaves a partial file under the final one.
  """
  def write_atomically(path, data) do
    File.mkdir_p!(Path.dirname(path))
    part = path <> ".part"
    File.write!(part, data)
    File.rename!(part, path)
  end

  @doc """
  The hint printed after a download when the project's .gitignore, given as
  its text or nil, does not cover the cache directory.
  """
  def gitignore_hint(gitignore) do
    lines = if gitignore, do: String.split(gitignore, "\n"), else: []

    if Enum.any?(lines, &(&1 |> String.trim() |> String.trim("/") == @cache_dir)) do
      nil
    else
      "Downloaded images are kept in #{@cache_dir}/. Keep it out of git with:\n" <>
        "  echo '/#{@cache_dir}/' >> .gitignore"
    end
  end

  @doc """
  The sha256 GitHub reports for a release asset, or nil for older assets.
  """
  def digest_from_asset(%{"digest" => "sha256:" <> hex}) when byte_size(hex) == 64 do
    String.downcase(hex)
  end

  def digest_from_asset(_asset), do: nil

  @doc """
  The Elixir image of a release for the connected chip, matched on the exact
  chip token: an ESP32-P4 gets the plain esp32p4 image, never one of its
  variants, and an ESP32 never an esp32s3 or esp32c6 one.
  """
  def select_release_image(images, tag, chip_token) do
    candidates = Enum.filter(images, &(&1.chip == chip_token))

    case Enum.find(candidates, & &1.elixir?) do
      %{} = image ->
        {:ok, image}

      nil when candidates == [] ->
        chips = images |> Enum.map(& &1.chip) |> Enum.uniq() |> Enum.sort()
        {:error, {:no_image_for_chip, tag, chip_token, chips}}

      nil ->
        {:error, {:no_elixir_image, tag, chip_token, hd(candidates).name}}
    end
  end

  def format_error({:no_image_for_chip, tag, chip_token, chips}) do
    "release #{tag} has no image for #{chip_token}; it has images for: #{Enum.join(chips, ", ")}"
  end

  def format_error({:no_elixir_image, tag, chip_token, erlang_name}) do
    "release #{tag} has no Elixir image for #{chip_token}, only the Erlang-only #{erlang_name}"
  end

  def format_error({:unrecognized_name, name}) do
    "#{name} is not an AtomVM ESP32 image name"
  end

  def format_error({:release_not_found, :atomvm, tag}) do
    "AtomVM release #{tag} not found"
  end

  def format_error({:http, url, {:status, 403}}) do
    "GitHub refused #{url}: the API rate limit (60 requests per hour without a token) " <>
      "may be exhausted, retry later or install a cached image"
  end

  def format_error({:http, url, {:status, status}}) do
    "GitHub answered #{status} for #{url}"
  end

  def format_error({:http, url, {:transport, reason}}) do
    "cannot reach #{url} (#{reason}); a cached image can still be installed"
  end

  def format_error({:size_mismatch, file, expected, actual}) do
    "#{file}: downloaded #{actual} bytes, #{expected} expected; the download was discarded"
  end

  def format_error({:digest_mismatch, file, expected, actual}) do
    "#{file}: sha256 #{actual} does not match the published #{expected}; the download was discarded"
  end

  def format_error(reason), do: inspect(reason)
end
