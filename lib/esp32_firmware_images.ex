defmodule ExAtomVM.Esp32FirmwareImages do
  @moduledoc false

  # Req is an optional dependency, see Mix.Tasks.Atomvm.Esp32.Install.
  @compile {:no_warn_undefined, Req}

  @atomvm_releases_url "https://api.github.com/repos/atomvm/atomvm/releases"
  @factory_releases_url "https://api.github.com/repos/atomvm/atomvm-esp32-firmware-factory/releases"
  @releases_page_size 10
  @cache_dir "firmware_images"
  @build_images_dir "_build/atomvm_images"

  @flash_offsets %{
    "esp32" => 0x1000,
    "esp32s2" => 0x1000,
    "esp32s3" => 0x0,
    "esp32c2" => 0x0,
    "esp32c3" => 0x0,
    "esp32c5" => 0x2000,
    "esp32c6" => 0x0,
    "esp32c61" => 0x0,
    "esp32h2" => 0x0,
    "esp32p4" => 0x2000
  }

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
  def release_images(%{"tag_name" => tag} = release, source \\ :atomvm) do
    assets = release["assets"] || []

    sidecars =
      for %{"name" => name, "browser_download_url" => url} <- assets,
          String.ends_with?(name, ".sha256"),
          into: %{},
          do: {String.replace_suffix(name, ".sha256", ""), url}

    for %{"name" => name} = asset <- assets,
        String.ends_with?(name, [".img", ".zip"]),
        image <- List.wrap(asset_image(name, tag, source)) do
      Map.merge(image, %{
        source: source,
        tag: tag,
        url: asset["browser_download_url"],
        size: asset["size"],
        published_at: date(release["published_at"]),
        sha256: digest_from_asset(asset),
        sha256_url: sidecars[name],
        channel: release_channel(image.channel, release["prerelease"]),
        stamp: image.stamp || rolling_stamp(image, release, asset)
      })
    end
  end

  # A repository of custom builds may name its images as it likes: those are
  # listed as they are and installed by name.
  defp asset_image(name, tag, {:repo, _repo}) do
    case parse_name(name) do
      {:ok, %{version: nil} = image} -> %{image | version: tag, channel: :custom}
      {:ok, image} -> image
      {:error, _reason} -> %{file_image(name) | version: tag, channel: :custom}
    end
  end

  defp asset_image(name, _tag, _source) do
    case parse_name(name) do
      {:ok, image} -> image
      {:error, _reason} -> nil
    end
  end

  defp date(<<date::binary-size(10), _::binary>>), do: date
  defp date(_), do: nil

  defp release_channel(:stable, true), do: :prerelease
  defp release_channel(channel, _prerelease), do: channel

  # The assets of a rolling tag keep their names from one build to the next.
  # A bundle carries its build stamp, which the factory also writes in the
  # release notes; a plain image is told apart by the day it was uploaded.
  defp rolling_stamp(%{kind: :zip}, release, _asset) do
    if rolling_tag?(release["tag_name"]), do: stamp_from_body(release["body"])
  end

  defp rolling_stamp(%{kind: :img, version: version}, release, asset) do
    with true <- rolling_tag?(release["tag_name"]),
         date when is_binary(date) <- date(asset["updated_at"]) do
      (version || release["tag_name"]) <> "+" <> String.replace(date, "-", "")
    else
      _ -> nil
    end
  end

  defp rolling_tag?(tag), do: not Regex.match?(~r/^v\d/, tag || "")

  @doc """
  The build stamp the factory writes in its release notes.
  """
  def stamp_from_body(body) when is_binary(body) do
    case Regex.run(~r/Build stamp: `([^`]+)`/, body) do
      [_, stamp] -> stamp
      nil -> nil
    end
  end

  def stamp_from_body(_body), do: nil

  @doc """
  A source of custom builds given as `--repo`: `OWNER/REPO`, or the URL of the
  repository on GitHub.
  """
  def parse_repo_arg(arg) do
    repo =
      arg
      |> String.trim()
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("github.com/", "")
      |> String.trim_trailing("/")
      |> String.replace_suffix("/releases", "")
      |> String.replace_suffix(".git", "")

    case String.split(repo, "/") do
      [owner, name] when owner != "" and name != "" ->
        if Regex.match?(~r|^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$|, repo),
          do: {:ok, repo},
          else: :error

      _parts ->
        :error
    end
  end

  @doc """
  Fetches a release of a source, the latest one when the tag is nil. A
  repository of custom builds may have no stable release, then its newest
  release is the latest.
  """
  def fetch_release({:repo, _repo} = source, nil) do
    case fetch_release_at(source, nil) do
      {:error, {:release_not_found, _source, nil}} ->
        with {:ok, releases} <- fetch_json(releases_url(source, :list)) do
          case Enum.reject(releases, & &1["draft"]) do
            [release | _older] -> {:ok, release}
            [] -> {:error, {:release_not_found, source, nil}}
          end
        end

      result ->
        result
    end
  end

  def fetch_release(source, tag), do: fetch_release_at(source, tag)

  defp fetch_release_at(source, tag) do
    case fetch_json(releases_url(source, tag)) do
      {:ok, release} -> {:ok, release}
      {:error, {:http, _url, {:status, 404}}} -> {:error, {:release_not_found, source, tag}}
      error -> error
    end
  end

  defp releases_url(source, :list),
    do: releases_base(source) <> "?per_page=#{@releases_page_size}"

  defp releases_url(source, nil), do: releases_base(source) <> "/latest"

  defp releases_url(source, tag) do
    releases_base(source) <> "/tags/" <> URI.encode(tag, &URI.char_unreserved?/1)
  end

  defp releases_base(:atomvm), do: @atomvm_releases_url
  defp releases_base(:factory), do: @factory_releases_url
  defp releases_base({:repo, repo}), do: "https://api.github.com/repos/#{repo}/releases"

  @doc """
  The sections of `--list-images`, one API call per source: the latest stable
  AtomVM release and the prereleases newer than it, then the nightly builds.
  """
  def fetch_listing(sources \\ [:atomvm, :factory]) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, sections} ->
      case fetch_json(releases_url(source, :list)) do
        {:ok, releases} -> {:cont, {:ok, sections ++ listing_sections(source, releases)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def listing_sections(:atomvm, releases) do
    %{stable: stable, prereleases: prereleases} = classify_releases(releases)

    for {kind, release} <-
          List.wrap(stable && {:stable, stable}) ++ Enum.map(prereleases, &{:prerelease, &1}) do
      label = if kind == :stable, do: "Stable release", else: "Prerelease"
      title = "#{label} #{release["tag_name"]} (#{date(release["published_at"])})"
      %{kind: kind, title: title, images: release_images(release, :atomvm)}
    end
  end

  def listing_sections(:factory, releases) do
    images =
      for release <- releases,
          not release["draft"],
          image <- release_images(release, :factory),
          do: image

    [%{kind: :nightly, title: "Nightly builds (atomvm-esp32-firmware-factory)", images: images}]
  end

  def listing_sections({:repo, repo} = source, releases) do
    for release <- releases, not release["draft"] do
      title =
        "Custom builds (#{repo}), release #{release["tag_name"]} (#{date(release["published_at"])})"

      %{kind: :custom, title: title, images: release_images(release, source)}
    end
  end

  @doc """
  The newest stable release and the prereleases newer than it, out of the
  list GitHub returns, newest first.
  """
  def classify_releases(releases) do
    case releases |> Enum.reject(& &1["draft"]) |> Enum.split_while(& &1["prerelease"]) do
      {prereleases, [stable | _older]} -> %{stable: stable, prereleases: prereleases}
      {prereleases, []} -> %{stable: nil, prereleases: prereleases}
    end
  end

  @doc """
  The images on disk: the cache, and what mix atomvm.esp32.build produced.
  """
  def local_section do
    %{kind: :local, title: "Local images", images: local_images()}
  end

  def local_images do
    dir = cache_dir()

    subdirs =
      case File.ls(dir) do
        {:ok, entries} -> entries |> Enum.sort() |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        {:error, _reason} -> []
      end

    cached =
      Enum.flat_map([dir | Enum.map(subdirs, &Path.join(dir, &1))], fn cache ->
        files(cache, Path.relative_to_cwd(cache), :cache)
      end)

    without_extracted(cached) ++ files(@build_images_dir, @build_images_dir, :build)
  end

  @doc """
  Drops the image extracted next to a cached bundle, listing the bundle only.
  """
  def without_extracted(images) do
    bundles = for %{kind: :zip} = image <- images, do: {image.name, image.stamp}

    Enum.reject(images, fn image ->
      image.kind == :img and {image.name, image.stamp} in bundles
    end)
  end

  defp files(dir, shown_as, source) do
    case File.ls(dir) do
      {:ok, files} ->
        for file <- Enum.sort(files), String.ends_with?(file, [".img", ".zip"]) do
          path = Path.join(dir, file)

          Map.merge(file_image(file), %{
            source: source,
            path: Path.join(shown_as, file),
            size: File.stat!(path).size
          })
        end

      {:error, _reason} ->
        []
    end
  end

  @doc """
  The text of `--list-images`: the sections, images for the chips in
  `:filter` only when given, after the `:header` lines.
  """
  def render_list(sections, opts \\ []) do
    filter = Keyword.get(opts, :filter)
    header = Keyword.get(opts, :header, [])

    published =
      for %{kind: :nightly, images: images} <- sections,
          image <- images,
          do: {image.name, image.stamp}

    {shown, hidden} =
      Enum.map_reduce(sections, 0, fn section, hidden ->
        {kept, dropped} = Enum.split_with(section.images, &listed?(&1, filter))
        {%{section | images: kept}, hidden + length(dropped)}
      end)

    body =
      for %{images: images} = section <- shown, images != [] do
        width = images |> Enum.map(&String.length(label(section, &1))) |> Enum.max()
        [section.title | Enum.flat_map(images, &row(section, &1, width, published))] ++ [""]
      end

    filter_line =
      if filter,
        do: [
          "Showing images for #{Enum.join(filter, ", ")}; pass --chip all to list every image."
        ],
        else: []

    intro = header ++ filter_line
    intro = if intro == [], do: [], else: intro ++ [""]
    hidden_line = if hidden > 0, do: ["#{hidden} images for other chips not shown.", ""], else: []

    footer = [
      "Install with:",
      "  mix atomvm.esp32.install --image <name or path>",
      "  mix atomvm.esp32.install --version <tag>        the Elixir image of a release",
      "Older releases: https://github.com/atomvm/AtomVM/releases",
      "None of these fits? mix atomvm.esp32.build builds a custom image from source."
    ]

    Enum.join(intro ++ List.flatten(body) ++ hidden_line ++ footer, "\n")
  end

  defp listed?(_image, nil), do: true

  defp listed?(image, chips) do
    chip = image_chip(image)
    chip == nil or chip in chips or image.chip in chips
  end

  defp label(%{kind: :local}, image), do: image.path
  defp label(_section, %{chip: nil} = image), do: image.file
  defp label(_section, image), do: image.name

  defp row(section, image, width, published) do
    columns = [
      String.pad_trailing(label(section, image), width),
      String.pad_trailing(flavor(image), 11),
      format_size(image.size)
    ]

    first = "  " <> Enum.join(columns, "  ") <> note(section, image, published)

    case section.kind do
      :nightly ->
        features =
          if image.features == [], do: "", else: ", features: " <> Enum.join(image.features, ", ")

        [first, "    build #{image.stamp || "unknown"} (#{image.published_at})#{features}"]

      _kind ->
        [first]
    end
  end

  defp note(%{kind: :local}, %{source: :build}, _published),
    do: "  built by mix atomvm.esp32.build"

  defp note(%{kind: :local}, %{channel: :nightly, stamp: stamp} = image, published)
       when is_binary(stamp) do
    if published == [] or {image.name, stamp} in published,
      do: "  cached",
      else: "  cached, no longer published"
  end

  defp note(%{kind: :local}, _image, _published), do: "  cached"
  defp note(%{kind: :custom}, %{chip: nil}, _published), do: "  install by name with --repo"
  defp note(_section, _image, _published), do: ""

  def format_size(nil), do: ""
  def format_size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  def format_size(bytes), do: "#{div(bytes + 1023, 1024)} KB"

  @doc """
  What `--image` names: a file, or a published image to fetch by name. With a
  repository of custom builds, any name is looked up there.
  """
  def classify_image_arg(arg, custom_source? \\ false) do
    if File.regular?(arg) do
      {:path, arg}
    else
      case parse_name(arg) do
        {:ok, %{version: version} = image} when is_binary(version) -> {:name, image}
        _ when custom_source? -> {:name, %{file_image(Path.basename(arg)) | channel: :custom}}
        _ -> :error
      end
    end
  end

  @doc """
  Finds a named image: in the newest release of a repository of custom builds
  that has it, otherwise on the source its version belongs to, the factory
  for a nightly channel and the AtomVM releases otherwise. Offline, a cached
  copy.
  """
  def resolve(image, source \\ nil)

  def resolve(%{name: name}, {:repo, _repo} = source) do
    case fetch_json(releases_url(source, :list)) do
      {:ok, releases} -> find_in_releases(releases, name, source)
      {:error, reason} -> cached_or(name, source, reason)
    end
  end

  def resolve(%{name: name, version: version, channel: channel}, nil) do
    source = if channel == :nightly, do: :factory, else: :atomvm

    case fetch_release(source, version) do
      {:ok, release} -> find_in_releases([release], name, source)
      {:error, {:release_not_found, _source, _tag}} -> {:error, {:unknown_image, name, source}}
      {:error, reason} -> cached_or(name, source, reason)
    end
  end

  @doc """
  The image called `name` in the newest of the releases that has it.
  """
  def find_in_releases(releases, name, source) do
    wanted = String.downcase(name)

    found =
      for release <- releases,
          not release["draft"],
          image <- release_images(release, source),
          String.downcase(image.name) == wanted,
          do: image

    case found do
      [image | _older] -> {:ok, image}
      [] -> {:error, {:unknown_image, name, source}}
    end
  end

  defp cached_or(name, source, reason) do
    case find_cached(name, source) do
      [image | _older] -> {:ok, image}
      [] -> {:error, reason}
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
    case Req.get(url, raw: true, redirect_log_level: false) do
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
  The cache directory of a source: the images of a repository of custom
  builds go in a subdirectory of their own.
  """
  def cache_dir({:repo, repo}), do: Path.join(cache_dir(), String.replace(repo, "/", "-"))
  def cache_dir(_source), do: cache_dir()

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
  def find_cached(name, source \\ :atomvm) do
    dir = cache_dir(source)

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
  `:path`, and whether it was `:cached` already or `:downloaded` now. A bundle
  is cached under its build stamp, with its image extracted next to it.
  """
  def ensure_cached(image, opts \\ [])

  # Found in the cache already, by find_cached/2.
  def ensure_cached(%{path: path, kind: kind} = image, opts) when is_binary(path) do
    log = Keyword.get(opts, :log, fn _message -> :ok end)

    cond do
      not File.exists?(path) -> {:error, {:not_cached, image.name}}
      kind == :zip -> with({:ok, image} <- load_bundle(image, path), do: {:ok, image, :cached})
      true -> {:ok, image, :cached}
    end
    |> tap(fn
      {:ok, _image, :cached} -> log.("Using cached #{Path.relative_to_cwd(path)}")
      _error -> :ok
    end)
  end

  def ensure_cached(%{kind: :zip} = image, opts) do
    log = Keyword.get(opts, :log, fn _message -> :ok end)
    dir = cache_dir(image.source)
    path = image.stamp && Path.join(dir, cached_file_name(image))

    if path && File.exists?(path) do
      log.("Using cached #{Path.relative_to_cwd(path)}")

      with {:ok, image} <- load_bundle(image, path) do
        {:ok, image, :cached}
      end
    else
      log.("Downloading #{image.file}, may take a while...")

      with {:ok, data, checked} <- download_verified(image),
           {:ok, bundle} <- verify_bundle(data, image.file, image.stamp) do
        if checked == :unverified do
          log.(
            "Warning: no checksum is published for #{image.file}, the download was not verified"
          )
        end

        image = %{image | stamp: bundle.stamp || image.stamp}
        path = Path.join(dir, cached_file_name(image))
        write_atomically(path, data)
        write_atomically(bundle_image_path(path), bundle.image)
        {:ok, with_bundle(image, path, bundle), :downloaded}
      end
    end
  end

  def ensure_cached(image, opts) do
    log = Keyword.get(opts, :log, fn _message -> :ok end)
    path = Path.join(cache_dir(image.source), cached_file_name(image))

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

  defp load_bundle(image, path) do
    with {:ok, bundle} <- verify_bundle(File.read!(path), Path.basename(path), image.stamp) do
      img_path = bundle_image_path(path)
      if not File.exists?(img_path), do: write_atomically(img_path, bundle.image)
      {:ok, with_bundle(%{image | stamp: bundle.stamp || image.stamp}, path, bundle)}
    end
  end

  defp with_bundle(image, path, bundle) do
    Map.merge(image, %{path: path, img_path: bundle_image_path(path), flash: bundle.flash})
  end

  defp bundle_image_path(zip_path), do: String.replace_suffix(zip_path, ".zip", ".img")

  @doc """
  An image file given by the user: parsed from its name when it follows the
  naming convention, taken as is otherwise.
  """
  def local_image(path) do
    Map.merge(file_image(Path.basename(path)), %{source: :local, path: path})
  end

  defp file_image(file) do
    case parse_name(file) do
      {:ok, image} ->
        image

      {:error, _reason} ->
        {stem, kind} = split_extension(file)

        %{
          name: stem,
          file: file,
          kind: kind || :img,
          chip: nil,
          base_chip: nil,
          elixir?: nil,
          features: [],
          version: nil,
          channel: :local,
          stamp: nil
        }
    end
  end

  @doc """
  A bundle file given by the user: verified, its image extracted into the
  cache under the bundle's build stamp.
  """
  def local_bundle(path) do
    file = Path.basename(path)

    with {:ok, bundle} <- verify_bundle(File.read!(path), file, nil) do
      image = %{local_image(String.replace_suffix(path, ".zip", ".img")) | kind: :zip, file: file}
      image = %{image | stamp: bundle.stamp, chip: image.chip || bundle.flash.chip}
      img_path = Path.join(cache_dir(), bundle_image_path(cached_file_name(image)))
      if not File.exists?(img_path), do: write_atomically(img_path, bundle.image)
      {:ok, Map.merge(image, %{path: path, img_path: img_path, flash: bundle.flash})}
    end
  end

  def image_path(image), do: Map.get(image, :img_path) || image.path

  def bundle_members(zip) do
    case :zip.list_dir(zip) do
      {:ok, entries} ->
        {:ok, for({:zip_file, name, _, _, _, _} <- entries, do: List.to_string(name))}

      {:error, _reason} ->
        :error
    end
  end

  def bundle_extract(zip, names) do
    case :zip.unzip(zip, [:memory, {:file_list, Enum.map(names, &String.to_charlist/1)}]) do
      {:ok, members} ->
        {:ok, Map.new(members, fn {name, data} -> {List.to_string(name), data} end)}

      {:error, _reason} ->
        :error
    end
  end

  @doc """
  Checks a bundle as the factory publishes it: the image with its .sha256,
  sdkconfig, partitions.csv and FLASH.txt, the parts of the image named in
  FLASH.txt, and SHA256SUMS covering them. The parts must be the image's
  bytes at their offsets, and the build stamp must be the expected one when
  given. Debug members are not read.
  """
  def verify_bundle(zip, file, expected_stamp) do
    with {:ok, names} <- bundle_members(zip) |> bad_bundle(file, :not_a_zip),
         {:ok, img_name} <- bundle_image_name(names) |> bad_bundle(file, :no_image),
         :ok <- members_present(names, ["FLASH.txt"]) |> bad_bundle(file),
         {:ok, %{"FLASH.txt" => flash_txt}} <-
           bundle_extract(zip, ["FLASH.txt"]) |> bad_bundle(file, :unreadable),
         {:ok, flash} <- parse_flash_txt(flash_txt) |> bad_bundle(file),
         part_names = Enum.map(flash.parts, & &1.name),
         summed = [img_name, "sdkconfig", "partitions.csv", "FLASH.txt" | part_names],
         wanted = [img_name <> ".sha256" | summed],
         :ok <- members_present(names, wanted) |> bad_bundle(file),
         sums = if("SHA256SUMS" in names, do: ["SHA256SUMS"], else: []),
         {:ok, members} <- bundle_extract(zip, wanted ++ sums) |> bad_bundle(file, :unreadable),
         image = members[img_name],
         :ok <-
           check_listed_sha256(img_name <> ".sha256", members, [img_name]) |> bad_bundle(file),
         :ok <- check_listed_sha256("SHA256SUMS", members, summed) |> bad_bundle(file),
         :ok <- check_parts_in_image(image, flash, members) |> bad_bundle(file),
         :ok <- check_bundle_chip(img_name, flash.chip) |> bad_bundle(file),
         stamp = bundle_stamp(members["sdkconfig"]),
         :ok <- check_stamp(stamp, expected_stamp, file) do
      {:ok,
       %{
         stem: String.replace_suffix(img_name, ".img", ""),
         image: image,
         flash: flash,
         stamp: stamp,
         parts: Map.take(members, part_names),
         partitions_csv: members["partitions.csv"]
       }}
    end
  end

  defp bad_bundle(:error, file, detail), do: {:error, {:bad_bundle, file, detail}}
  defp bad_bundle({:ok, []}, file, detail), do: {:error, {:bad_bundle, file, detail}}
  defp bad_bundle(result, _file, _detail), do: result

  defp bad_bundle({:error, detail}, file), do: {:error, {:bad_bundle, file, detail}}
  defp bad_bundle(result, _file), do: result

  defp bundle_image_name(names) do
    case Enum.filter(names, &String.ends_with?(&1, ".img")) do
      [name] -> {:ok, name}
      _names -> :error
    end
  end

  defp members_present(names, wanted) do
    case wanted -- names do
      [] -> :ok
      missing -> {:error, {:missing_members, missing}}
    end
  end

  defp check_listed_sha256(sums_name, members, names) do
    case members[sums_name] do
      nil ->
        :ok

      text ->
        Enum.find_value(parse_sha256_lines(text), :ok, fn {hex, name} ->
          with true <- name in names,
               {:error, _reason} <- verify_sha256(members[name], hex) do
            {:error, {:sha256_mismatch, name}}
          else
            _ -> nil
          end
        end)
    end
  end

  defp check_parts_in_image(image, flash, members) do
    Enum.find_value(flash.parts, :ok, fn %{name: name, offset: offset} ->
      data = members[name]
      start = offset - flash.flash_offset

      if start >= 0 and start + byte_size(data) <= byte_size(image) and
           binary_part(image, start, byte_size(data)) == data,
         do: nil,
         else: {:error, {:part_mismatch, name, offset}}
    end)
  end

  defp check_bundle_chip(img_name, flash_chip) do
    case parse_name(img_name) do
      {:ok, %{base_chip: chip}} when chip != flash_chip -> {:error, {:chip, flash_chip, chip}}
      _ -> :ok
    end
  end

  defp check_stamp(stamp, expected, file) do
    if is_binary(stamp) and is_binary(expected) and stamp != expected do
      {:error, {:stamp_mismatch, file, expected, stamp}}
    else
      :ok
    end
  end

  @doc """
  The header and the Contents section of a bundle's FLASH.txt.
  """
  def parse_flash_txt(text) do
    fields = %{
      image: capture(text, ~r/^AtomVM firmware image: (\S+)$/m),
      chip: capture(text, ~r/^Chip: (\S+)$/m),
      build: capture(text, ~r/^AtomVM build: (\S+)$/m),
      idf: capture(text, ~r/^ESP-IDF: (\S+)$/m),
      flash_offset: capture(text, ~r/^Flash offset: (0x[0-9a-fA-F]+)$/m),
      app_offset: capture(text, ~r/^Application partition \(main\.avm\): (0x[0-9a-fA-F]+)$/m),
      parts: contents(text)
    }

    cond do
      fields.chip == nil ->
        {:error, {:bad_flash_txt, :chip}}

      fields.flash_offset == nil ->
        {:error, {:bad_flash_txt, :flash_offset}}

      true ->
        {:ok,
         %{
           fields
           | flash_offset: hex(fields.flash_offset),
             app_offset: fields.app_offset && hex(fields.app_offset)
         }}
    end
  end

  defp capture(text, regex) do
    case Regex.run(regex, text) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp hex("0x" <> digits), do: String.to_integer(digits, 16)

  # The "Contents" section lists the parts of the image, one "<offset> <name>"
  # line each; it ends where the next section's title is underlined.
  defp contents(text) do
    text
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "Contents"))
    |> Enum.drop(2)
    |> Enum.take_while(&(not Regex.match?(~r/^-+$/, &1)))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s+(0x[0-9a-fA-F]+)\s+(\S+)$/, line) do
        [_, offset, name] -> [%{name: name, offset: hex(offset)}]
        nil -> []
      end
    end)
  end

  @doc """
  The build stamp of a bundle, `CONFIG_APP_PROJECT_VER` in its sdkconfig.
  """
  def bundle_stamp(sdkconfig) when is_binary(sdkconfig) do
    capture(sdkconfig, ~r/^CONFIG_APP_PROJECT_VER="([^"]*)"$/m)
  end

  def bundle_stamp(_sdkconfig), do: nil

  @doc """
  Whether an image was built for the connected chip; `:unknown` when the
  image does not say which chip it is for.
  """
  def compatible?(image, chip_token) do
    case image_chip(image) do
      nil -> :unknown
      chip -> chip == chip_token
    end
  end

  def image_chip(%{base_chip: chip}) when is_binary(chip), do: chip
  def image_chip(%{flash: %{chip: chip}}), do: chip
  def image_chip(_image), do: nil

  @doc """
  The offset an image is flashed at: the one its bundle states, the chip's
  bootloader offset otherwise; both when known, and they must agree.
  """
  def flash_offset_for(image, chip_token) do
    bundle_offset = Map.get(image, :flash) && image.flash.flash_offset

    case {bundle_offset, @flash_offsets[chip_token]} do
      {nil, nil} -> {:error, {:unknown_flash_offset, chip_token}}
      {nil, offset} -> {:ok, offset}
      {offset, nil} -> {:ok, offset}
      {offset, offset} -> {:ok, offset}
      {bundle, table} -> {:error, {:flash_offset_conflict, image.file, bundle, table}}
    end
  end

  def describe(image, flash_offset) do
    details = [
      image.stamp && "  build:    #{image.stamp}",
      image.features != [] && "  features: #{Enum.join(image.features, ", ")}",
      "  offset:   #{format_hex(flash_offset)}"
    ]

    ["#{image.name} (#{origin(image)})" | Enum.filter(details, &is_binary/1)]
  end

  defp origin(%{channel: :stable, version: version} = image),
    do: "stable release #{version}, #{flavor(image)}"

  defp origin(%{channel: :prerelease, version: version} = image),
    do: "prerelease #{version}, #{flavor(image)}"

  defp origin(%{channel: :nightly, version: version} = image),
    do: "nightly build #{version}, #{flavor(image)}"

  defp origin(%{channel: :custom, version: version} = image),
    do: "custom build, release #{version}, #{flavor(image)}"

  defp origin(image), do: "local image, #{flavor(image)}"

  defp flavor(%{elixir?: true}), do: "Elixir"
  defp flavor(%{elixir?: false}), do: "Erlang only"
  defp flavor(_image), do: "unknown"

  def format_hex(integer), do: "0x" <> Integer.to_string(integer, 16)

  def warnings(image, chip_token) do
    [
      image.elixir? == false &&
        "this image has no Elixir support; the Elixir application of this project will not run on it",
      compatible?(image, chip_token) == :unknown &&
        "the chip this image was built for is not known; esptool refuses images built for another chip"
    ]
    |> Enum.filter(&is_binary/1)
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

  @partition_table_offset 0x8000
  @partition_table_size 0xC00
  @bootloader_desc_offset 0x20

  @doc """
  What an update writes, the VM (the app partition) and the boot library,
  with the partition table and the bootloader of the image to check the
  board against: the parts of a bundle, or slices of an image cut along the
  partition table embedded in it.
  """
  def update_parts(%{kind: :zip, path: path} = image, _base) do
    with {:ok, bundle} <- verify_bundle(File.read!(path), Path.basename(path), image.stamp) do
      bundle_update_parts(bundle)
    end
  end

  def update_parts(image, base) do
    slice_image(File.read!(image_path(image)), base)
  end

  def bundle_update_parts(%{parts: parts, flash: flash, image: image})
      when map_size(parts) == 0 do
    slice_image(image, flash.flash_offset)
  end

  def bundle_update_parts(%{parts: parts, flash: flash, stem: stem}) do
    offsets = Map.new(flash.parts, &{&1.name, &1.offset})
    lib_name = Enum.find(Map.keys(parts), &String.ends_with?(&1, ".avm"))

    wanted = [
      "bootloader.bin",
      "partition-table.bin",
      "atomvm-esp32.bin",
      lib_name || "boot library"
    ]

    case wanted -- Map.keys(parts) do
      [] ->
        {:ok,
         %{
           bootloader: parts["bootloader.bin"],
           table: parts["partition-table.bin"],
           app: {offsets["atomvm-esp32.bin"], "atomvm-esp32.bin", parts["atomvm-esp32.bin"]},
           lib: {offsets[lib_name], lib_name, parts[lib_name]}
         }}

      missing ->
        {:error, {:bad_bundle, stem <> ".zip", {:missing_members, missing}}}
    end
  end

  @doc """
  The parts of a plain image: its partition table says where the `factory`
  and `boot.avm` partitions are; the trailing 0xFF of each slice is dropped,
  since erased flash reads 0xFF.
  """
  def slice_image(img, base) do
    table_start = @partition_table_offset - base

    with :ok <- long_enough(img, table_start + @partition_table_size),
         table = binary_part(img, table_start, @partition_table_size),
         {:ok, partitions} <- parse_table(table, :image),
         {:ok, factory} <- partition(partitions, "factory"),
         {:ok, boot} <- partition(partitions, "boot.avm"),
         {:ok, app} <- slice(img, base, factory),
         {:ok, lib} <- slice(img, base, boot) do
      {:ok,
       %{
         bootloader: trim_erased(binary_part(img, 0, table_start)),
         table: table,
         app: {factory.offset, "factory.bin", app},
         lib: {boot.offset, "boot.avm", lib}
       }}
    end
  end

  defp long_enough(img, size) when byte_size(img) >= size, do: :ok
  defp long_enough(_img, _size), do: {:error, {:bad_image, :truncated}}

  defp parse_table(table, side) do
    case ExAtomVM.Esp32PartitionTable.parse(table) do
      {:ok, partitions} -> {:ok, partitions}
      {:error, reason} -> {:error, {:partition_mismatch, {:unreadable, side, reason}}}
    end
  end

  defp partition(partitions, name) do
    case Enum.find(partitions, &(&1.name == name)) do
      nil -> {:error, {:partition_mismatch, {:missing, name}}}
      partition -> {:ok, partition}
    end
  end

  defp slice(img, base, %{offset: offset, size: size, name: name}) do
    start = offset - base

    data =
      if start >= 0 and start < byte_size(img),
        do: trim_erased(binary_part(img, start, min(size, byte_size(img) - start))),
        else: <<>>

    if data == <<>>, do: {:error, {:bad_image, {:no_data, name}}}, else: {:ok, data}
  end

  defp trim_erased(bin), do: trim_erased(bin, byte_size(bin))
  defp trim_erased(_bin, 0), do: <<>>

  defp trim_erased(bin, size) do
    if :binary.at(bin, size - 1) == 0xFF,
      do: trim_erased(bin, size - 1),
      else: binary_part(bin, 0, size)
  end

  @doc """
  The descriptor ESP-IDF writes into a bootloader since version 5.1, with
  the ESP-IDF version it was built with.
  """
  def bootloader_desc(
        <<_::binary-size(@bootloader_desc_offset), 0x50, _::binary-size(7),
          idf_ver::binary-size(32), _::binary>>
      ) do
    {:ok, %{idf_ver: idf_ver |> :binary.split(<<0>>) |> hd()}}
  end

  def bootloader_desc(_bin), do: :error

  @doc """
  Compares two ESP-IDF versions, `v5.5.4` or `5.5.4`.
  """
  def compare_idf(a, b) do
    case {idf_version(a), idf_version(b)} do
      {nil, _b} -> :unknown
      {_a, nil} -> :unknown
      {x, y} when x > y -> :gt
      {x, y} when x < y -> :lt
      _equal -> :eq
    end
  end

  defp idf_version(version) when is_binary(version) do
    case Regex.run(~r/^v?(\d+)\.(\d+)(?:\.(\d+))?/, version) do
      [_, major, minor] ->
        {String.to_integer(major), String.to_integer(minor), 0}

      [_, major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}

      nil ->
        nil
    end
  end

  defp idf_version(_version), do: nil

  @doc """
  The rule of the factory's FLASH.txt: the board's bootloader must not come
  from a newer ESP-IDF than the image, since a bootloader does not start an
  app built with an older ESP-IDF. Unknown versions get a warning.
  """
  def check_bootloader(board_bootloader, image_bootloader) do
    board = idf_of(board_bootloader)
    image = idf_of(image_bootloader)

    case compare_idf(board, image) do
      :gt ->
        {:error, {:bootloader_newer, board, image}}

      :unknown ->
        {:ok,
         %{
           board: board,
           image: image,
           warning:
             "the ESP-IDF versions of the board's bootloader (#{board || "unknown"}) and of " <>
               "the image (#{image || "unknown"}) cannot be compared; a VM built with an older " <>
               "ESP-IDF than the bootloader does not start"
         }}

      _older_or_same ->
        {:ok, %{board: board, image: image, warning: nil}}
    end
  end

  defp idf_of(bin) do
    case bootloader_desc(bin) do
      {:ok, %{idf_ver: version}} -> version
      :error -> nil
    end
  end

  @doc """
  An update keeps every partition but the two it writes, so the `factory`
  and `boot.avm` entries of the board's table must equal the image's, and
  the parts must fit them. The other entries may differ: an expanded
  `main.avm` is fine, AtomVM finds its partitions by label.
  """
  def check_update_layout(board_table, image_table, app_size, lib_size) do
    with {:ok, board} <- parse_table(board_table, :board),
         {:ok, image} <- parse_table(image_table, :image),
         {:ok, factory} <- same_partition(board, image, "factory"),
         {:ok, boot} <- same_partition(board, image, "boot.avm"),
         :ok <- fits(app_size, factory),
         :ok <- fits(lib_size, boot) do
      :ok
    end
  end

  defp same_partition(board, image, name) do
    with {:ok, on_board} <- partition(board, name),
         {:ok, in_image} <- partition(image, name) do
      keys = [:type, :subtype, :offset, :size]

      if Map.take(on_board, keys) == Map.take(in_image, keys),
        do: {:ok, in_image},
        else: {:error, {:partition_mismatch, {name, on_board, in_image}}}
    end
  end

  defp fits(size, %{size: max}) when size <= max, do: :ok
  defp fits(size, %{size: max, name: name}), do: {:error, {:part_too_large, name, size, max}}

  @doc """
  The lines describing an update in the confirmation prompt.
  """
  def update_summary(installed, board_idf, image, parts) do
    %{app: {app_offset, app_name, _app}, lib: {lib_offset, lib_name, _lib}} = parts
    bootloader = if board_idf, do: " (bootloader ESP-IDF #{board_idf})", else: ""
    build = if image.stamp, do: ", build #{image.stamp}", else: ""

    [
      "  from:  #{installed || "unknown build"}#{bootloader}",
      "  to:    #{image.name} (#{origin(image)})#{build}",
      "  writes #{app_name} at #{format_hex(app_offset)} and #{lib_name} at #{format_hex(lib_offset)}",
      "The bootloader, the partition table, NVS and main.avm are kept."
    ]
  end

  def format_error({:no_image_for_chip, tag, chip_token, []}) do
    "release #{tag} has no image named for #{chip_token}; " <>
      "custom builds are installed by name with --image"
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

  def format_error({:release_not_found, source, nil}) do
    "#{source_name(source)} has no release"
  end

  def format_error({:release_not_found, source, tag}) do
    "#{source_name(source)} has no release #{tag}"
  end

  def format_error({:unknown_image, name, source}) do
    "#{source_name(source)} publishes no image called #{name}"
  end

  def format_error({:not_cached, name}) do
    "#{name} is not in #{@cache_dir}/"
  end

  def format_error({:bad_bundle, file, detail}) do
    "#{file} is not a valid firmware bundle: #{bundle_detail(detail)}"
  end

  def format_error({:stamp_mismatch, file, expected, actual}) do
    "#{file} carries build #{actual} while the release notes say #{expected}; " <>
      "the factory may be publishing a new build, retry in a few minutes"
  end

  def format_error({:chip_mismatch, file, image_chip, chip_family}) do
    "#{file} was built for #{image_chip}, the connected chip is #{chip_family}"
  end

  def format_error({:flash_offset_conflict, file, bundle, table}) do
    "#{file} says it is flashed at #{format_hex(bundle)}, the chip's bootloader offset is #{format_hex(table)}"
  end

  def format_error({:unknown_flash_offset, chip_token}) do
    "no flash offset is known for #{chip_token}; install a bundle, which states it"
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

  def format_error(:not_installed) do
    "no AtomVM installation was found on the board; run without --update to install one"
  end

  def format_error({:bad_image, :truncated}) do
    "the image is too short to hold a partition table"
  end

  def format_error({:bad_image, {:no_data, name}}) do
    "the image has no data for the #{name} partition"
  end

  def format_error({:partition_mismatch, {:unreadable, side, reason}}) do
    "the partition table of the #{side} cannot be read (#{inspect(reason)})"
  end

  def format_error({:partition_mismatch, {:missing, name}}) do
    "no #{name} partition in the partition table; install the whole image (without --update)"
  end

  def format_error({:partition_mismatch, {name, on_board, in_image}}) do
    "the #{name} partition differs: #{format_hex(on_board.offset)}+#{format_hex(on_board.size)} " <>
      "on the board, #{format_hex(in_image.offset)}+#{format_hex(in_image.size)} in the image; " <>
      "install the whole image (without --update)"
  end

  def format_error({:part_too_large, name, size, max}) do
    "#{size} bytes do not fit the #{name} partition of #{max} bytes; " <>
      "install the whole image (without --update)"
  end

  def format_error({:bootloader_newer, board, image}) do
    "the board's bootloader comes from ESP-IDF #{board}, newer than the image's #{image}, " <>
      "and would not start it; install the whole image (without --update)"
  end

  def format_error({:pythonx_error, message}), do: message
  def format_error(:flash_read_failed), do: "reading the flash failed"

  def format_error(reason), do: inspect(reason)

  defp source_name(:atomvm), do: "the AtomVM releases"
  defp source_name(:factory), do: "the firmware factory"
  defp source_name({:repo, repo}), do: "the #{repo} repository"

  defp bundle_detail(:not_a_zip), do: "not a zip file"
  defp bundle_detail(:no_image), do: "it does not contain exactly one .img file"
  defp bundle_detail(:unreadable), do: "its members cannot be read"
  defp bundle_detail({:missing_members, names}), do: "#{Enum.join(names, ", ")} missing"
  defp bundle_detail({:bad_flash_txt, field}), do: "FLASH.txt does not state the #{field}"
  defp bundle_detail({:sha256_mismatch, name}), do: "#{name} does not match its checksum"

  defp bundle_detail({:part_mismatch, name, offset}),
    do: "#{name} differs from the image at #{format_hex(offset)}"

  defp bundle_detail({:chip, flash_chip, name_chip}),
    do: "built for #{flash_chip}, named for #{name_chip}"

  defp bundle_detail(detail), do: inspect(detail)
end
