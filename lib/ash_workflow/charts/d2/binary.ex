defmodule AshWorkflow.Charts.D2.Binary do
  @moduledoc """
  Downloads the `d2` command and runs it, so `AshWorkflow.Charts.D2` can give
  you an SVG with no tool to install first.

  D2 is a Go program, and no Hex package wraps it. This module works the way
  the `esbuild` and `tailwind` packages do:

  1. The first time you ask for an SVG, it downloads the `d2` release for
     your platform from GitHub.
  2. It checks the download against the SHA-256 that ships with the release.
  3. It unpacks `d2` into `_build/d2-v<version>-<platform>/bin/d2`, beside
     the project's build directory, and keeps it there. The platform is in
     the name, so a `_build` that two platforms share keeps one binary for
     each. When `MIX_BUILD_PATH` is set, `d2` goes inside that directory.
  4. It runs `d2` as an external process for each SVG.

  You usually need nothing from this module directly. Call
  `AshWorkflow.Charts.render(resource, :d2, svg: true)`, and it does the rest.

  ## Configuration

      config :ash_workflow, :d2,
        version: "0.9.0",
        path: "/usr/local/bin/d2"

  * `:path` — a `d2` you installed yourself. A name with no `/`, such as
    `"d2"`, is a command on the `PATH`. A path with a `/` is a file, relative
    to the current directory, and `~` is the home directory. The file must
    be executable. When it is set, nothing is downloaded.
  * `:version` — the release to download. Defaults to the release this
    library pins, which is the only one it has checksums for.
  * `:checksums` — for a `:version` that this library does not pin, the
    SHA-256 of each tarball, as hex. It is a map from the platform part of
    the tarball name, such as `"linux-amd64"` or `"macos-arm64"`, to the
    sum. Case and surrounding whitespace of a sum do not matter. The pinned
    version always uses the sums that ship with this library, and ignores
    this map.

  A key set to `nil` is the same as a key that is not set, and a `:path` of
  `""` is the same as no `:path`. So `path: System.get_env("D2_PATH")`
  downloads `d2` when the variable is not set or is empty. Any other
  `:path` that is not a string raises `ArgumentError`, and so does a config
  that is not a keyword list.

  For example, for a version that this library does not pin:

      config :ash_workflow, :d2,
        version: "0.9.1",
        checksums: %{
          "linux-amd64" => "<SHA-256 of d2-v0.9.1-linux-amd64.tar.gz>",
          "macos-arm64" => "<SHA-256 of d2-v0.9.1-macos-arm64.tar.gz>"
        }

  ## Continuous integration

  `mix ash_workflow.d2.install` downloads `d2` ahead of time. Run it in a
  step that has network access, before the tests run. A CI cache of the
  `_build/d2-v*` directories keeps the binary between runs.

  The test helper of this library never downloads `d2`. When `d2` is not
  installed, it excludes the tests tagged `:d2` and prints a line that tells
  you to run `mix ash_workflow.d2.install`. The CI of this library runs that
  task before `mix check`, so CI runs those tests.

  ## Releases

  `mix release` does not copy `_build/d2-v<version>-<platform>`. So a release cannot
  use a `d2` that was downloaded at build time. Install `d2` on the host, or
  copy it into the release, and set `:path` to it in `config/runtime.exs`.
  Without `:path`, the first `svg: true` call in a release tries to download
  `d2` into the release's working directory.

  ## Network

  The download uses `:httpc` and checks the server's certificate against the
  operating system's CA certificates. It reads these variables, as Mix does:

  * `HTTPS_PROXY` and `HTTP_PROXY`, and their lowercase forms, as
    `host:port` or as a URL. A user name and a password in the URL go to the
    proxy.
  * `NO_PROXY` or `no_proxy`, a comma-separated list of hosts to reach with
    no proxy.
  * `HEX_CACERTS_PATH`, a file of CA certificates to use in place of the
    operating system's. Use it on a network that signs TLS with its own CA.

  A download that takes more than 10 minutes fails. At that limit, the
  tarball of 16 to 18 MB needs a link of about 0.25 Mbit/s.

  The proxy applies only to the download. It does not change the proxy of
  other `:httpc` requests in the VM.

  The download sends a line to standard error before it starts, and not to
  standard output. So `mix ash_workflow.diagram --format d2 --svg` can write
  to a file through `>`.

  The download needs the `:crypto`, `:public_key`, `:inets` and `:ssl`
  applications. Under Mix, it adds them to the code path and starts them,
  also in a project that does not list them. This library does not list
  them as applications, so a release does not start them at boot. A release
  that must download `d2` must include them itself, for example in its own
  `extra_applications`. Or it sets `:path`, and then it downloads nothing.

  When several processes in one VM need `d2` at the same time, one of them
  downloads it and the others wait for it.

  ## The `d2` process

  `d2` reads settings such as `D2_THEME`, `D2_LAYOUT` and `SCALE` from its
  environment, and they take precedence over the settings in the file. So
  this module runs `d2` with every `D2_*` variable removed from its
  environment, and with the other variables that `d2` reads removed too.
  The chart's options then decide the theme and the layout.

  `d2` prints a `success:` line for each chart that it draws, and this
  module drops that line. When `d2` draws the chart but prints another
  message, such as a warning, `render_svg!/2` logs the message with
  `Logger.warning/1`.
  """

  alias AshWorkflow.Charts.Command

  require Logger

  # Keep the version in the moduledoc example in step with this.
  @default_version "0.9.0"

  # The SHA256SUMS file of each pinned release, keyed by version and then by
  # the tarball's platform part.
  @checksums %{
    "0.9.0" => %{
      "linux-amd64" => "5669ddc46b99e942cc96078f4a4e36d5e62103348f4c05179ede27802fdd87a9",
      "linux-arm64" => "ac2c028697199479acb321db1e3d68caee9f2ba492ed73caa3cd13f3829bf913",
      "macos-amd64" => "cad39576a480d6bb02ea142fef1726647914b0d2da51ccc9b30b660a2b1babf0",
      "macos-arm64" => "eaf6c0c143e56dd9fa97bfb6df25ea9c1ebce40245f056a0768cf1a6c15d3064",
      "windows-amd64" => "5f63b643de8f5a6dfb922d172e1b5496e4caf47497c33c4427cf1127f28c340f",
      "windows-arm64" => "dd05cab459410c287d7ca3eb9cf78145a071742ee8e1b81a0122f84f471883e1"
    }
  }

  @doc """
  The release this library downloads when `:version` is not configured.
  """
  @spec default_version() :: String.t()
  def default_version, do: @default_version

  @doc """
  The configured release version.
  """
  @spec version() :: String.t()
  def version, do: config(:version) || @default_version

  @doc """
  The platform part of the tarball name for this machine, such as
  `"macos-arm64"`.

  Raises `ArgumentError` on a platform D2 has no release for.
  """
  @spec target() :: String.t()
  def target do
    case fetch_target() do
      {:ok, target} -> target
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp release_target?, do: match?({:ok, _target}, fetch_target())

  defp fetch_target do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    case {:os.type(), arch} do
      {{:win32, _}, _} -> {:ok, "windows-" <> windows_arch()}
      {{:unix, :darwin}, "aarch64" <> _} -> {:ok, "macos-arm64"}
      {{:unix, :darwin}, "x86_64" <> _} -> {:ok, "macos-amd64"}
      {{:unix, :linux}, "aarch64" <> _} -> {:ok, "linux-arm64"}
      {{:unix, :linux}, "x86_64" <> _} -> {:ok, "linux-amd64"}
      {os, _} -> {:error, "d2 has no release for #{inspect(os)} on #{arch}"}
    end
  end

  defp windows_arch do
    if System.get_env("PROCESSOR_ARCHITECTURE") == "ARM64", do: "arm64", else: "amd64"
  end

  @doc """
  The URL of the release tarball for a version and a platform part.
  """
  @spec url(String.t(), String.t()) :: String.t()
  def url(version \\ version(), target \\ target()) do
    "https://github.com/terrastruct/d2/releases/download/v#{version}/d2-v#{version}-#{target}.tar.gz"
  end

  @doc """
  The path of the `d2` binary: the configured `:path`, or where a download
  lands.
  """
  @spec path() :: Path.t()
  def path do
    case configured_path() do
      {:ok, path} -> path
      :error -> download_path()
    end
  end

  # `nil` and `""` are the same as no `:path`, so a runtime config can read
  # the path from a variable that may not be set, or that is empty.
  defp configured_path do
    case config(:path) do
      path when path in [nil, ""] ->
        :error

      path when is_binary(path) ->
        {:ok, path}

      other ->
        raise ArgumentError,
              "config :ash_workflow, :d2, path: must be a string, got: #{inspect(other)}"
    end
  end

  defp download_path, do: Path.join([install_dir(version()), "bin", executable_name()])

  # The platform is in the name, so a `_build` that a macOS host and a Linux
  # container share holds one binary for each, and neither runs the other's.
  defp install_dir(version), do: Path.join(base_dir(), "d2-v#{version}-#{target()}")

  defp executable_name do
    case :os.type() do
      {:win32, _} -> "d2.exe"
      _ -> "d2"
    end
  end

  # `_build` next to the project's build directory under Mix, so the binary
  # sits with the compiled code and a CI cache of `_build` keeps it.
  # `MIX_BUILD_PATH` names the build directory itself, and its parent can be
  # any directory, so then the binary goes inside it. Outside Mix, `_build`
  # under the current directory.
  defp base_dir do
    cond do
      not mix_running?() -> Path.join(File.cwd!(), "_build")
      System.get_env("MIX_BUILD_PATH") -> Mix.Project.build_path()
      true -> Mix.Project.build_path() |> Path.dirname()
    end
  end

  # Mix's modules can be on the code path when Mix is not running, for
  # example in a release that includes Mix. Its functions then fail.
  defp mix_running?, do: Process.whereis(Mix.State) != nil

  @doc """
  Whether the binary is there: the configured `:path` names an executable
  file or a command on the `PATH`, or the download is at `path/0`.

  Returns `false` on a platform that D2 has no release for, with no `:path`.
  """
  @spec installed?() :: boolean()
  def installed? do
    case configured_path() do
      {:ok, path} -> Command.find(path) != nil
      :error -> release_target?() and File.regular?(download_path())
    end
  end

  @doc """
  The path of the binary to run, after a download when it is missing.

  The download holds a lock, so when several processes in the VM call this
  at the same time, one downloads and the others wait for it.

  Raises `ArgumentError` when `:path` is configured and names neither an
  executable file nor a command on the `PATH`.
  """
  @spec ensure_installed!() :: Path.t()
  def ensure_installed! do
    case configured_path() do
      {:ok, path} ->
        Command.find(path) ||
          raise ArgumentError,
                "config :ash_workflow, :d2 sets :path to #{inspect(path)}, " <>
                  "which is neither an executable file nor a command on the PATH"

      :error ->
        if File.regular?(download_path()), do: download_path(), else: install_once!()
    end
  end

  # A process that waited for the lock finds the binary there and does not
  # download it again.
  defp install_once! do
    with_install_lock(fn ->
      if File.regular?(download_path()), do: download_path(), else: download_and_unpack!()
    end)
  end

  # The lock is per VM: the binary is on this host's disk, so a node on
  # another host must not wait for it. Two OS processes can still both
  # download, and the move into place in `download_and_unpack!/0` keeps that
  # safe. The lock also keeps two downloads in one VM off the shared `:httpc`
  # profile at the same time.
  defp with_install_lock(fun),
    do: :global.trans({{__MODULE__, :install}, self()}, fun, [node()])

  @doc """
  Downloads the release tarball, checks its SHA-256, and unpacks `d2` to
  `path/0`. Returns that path.

  Raises when the platform has no release, when the version is not pinned
  and `:checksums` has no sum for this platform, when the sum does not match,
  or when the download fails. It holds the same lock as `ensure_installed!/0`.
  """
  @spec install!() :: Path.t()
  def install! do
    with {:ok, path} <- configured_path() do
      raise ArgumentError,
            "config :ash_workflow, :d2 sets :path to #{inspect(path)}, so there is nothing to install"
    end

    with_install_lock(&download_and_unpack!/0)
  end

  defp download_and_unpack! do
    version = version()
    target = target()
    url = url(version, target)
    expected = expected_checksum!(version, target)
    dir = install_dir(version)

    # Standard error, so the line does not go into an SVG that a mix task
    # writes to standard output.
    IO.puts(:stderr, "Downloading d2 v#{version} for #{target} from #{url}")
    tarball = download!(url)
    verify_checksum!(tarball, expected)

    # Unpack beside the final directory and move it into place in one step,
    # so two processes that install at the same time cannot see a half-written
    # binary. The second move finds the directory there, and the first install
    # wins. The staging directory goes on every path out, so a failed extract
    # leaves nothing in `_build`.
    staging = "#{dir}.tmp-#{Command.unique_name()}"

    try do
      File.mkdir_p!(staging)
      unpack!(tarball, staging)
      unpacked = Path.join(staging, "d2-v#{version}")
      File.chmod!(Path.join([unpacked, "bin", executable_name()]), 0o755)
      move_into_place!(unpacked, dir)
    after
      File.rm_rf(staging)
    end

    # A directory that was already there may be incomplete, for example after
    # someone deleted the binary but not its directory. Say so, rather than
    # report an install that has no binary.
    if not File.regular?(download_path()) do
      raise "d2 is not at #{download_path()} after the install. Remove #{dir} and try again."
    end

    download_path()
  end

  defp unpack!(tarball, dir) do
    case :erl_tar.extract({:binary, tarball}, [:compressed, {:cwd, String.to_charlist(dir)}]) do
      :ok -> :ok
      {:error, reason} -> raise "could not unpack the d2 download: #{inspect(reason)}"
    end
  end

  defp move_into_place!(source, destination) do
    case File.rename(source, destination) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eexist, :enotempty] ->
        :ok

      {:error, reason} ->
        raise File.RenameError,
          reason: reason,
          source: source,
          destination: destination,
          action: "rename"
    end
  end

  @doc """
  The SHA-256 of the tarball for a version and a platform part, as lowercase
  hex.

  A version that this library pins always gets its pinned sum. Any other
  version gets the sum for the platform from `:checksums`. Raises
  `ArgumentError` when `:checksums` has no sum for the platform.
  """
  @spec expected_checksum!(String.t(), String.t()) :: String.t()
  def expected_checksum!(version, target) do
    case Map.fetch(@checksums, version) do
      {:ok, sums} ->
        Map.fetch!(sums, target)

      :error ->
        case (config(:checksums) || %{}) |> Map.fetch(target) do
          {:ok, checksum} ->
            checksum |> String.trim() |> String.downcase()

          :error ->
            raise ArgumentError,
                  "ash_workflow has no checksum for d2 v#{version} on #{target}. " <>
                    "Set #{inspect(target)} in :checksums under config :ash_workflow, :d2, " <>
                    "or use version #{@default_version}."
        end
    end
  end

  @doc """
  Raises `ArgumentError` unless the SHA-256 of the data equals the expected
  digest, given as lowercase hex.
  """
  @spec verify_checksum!(binary(), String.t()) :: :ok
  def verify_checksum!(data, expected) do
    actual = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    if actual == expected do
      :ok
    else
      raise ArgumentError,
            "the d2 download does not match its checksum: expected #{expected}, got #{actual}"
    end
  end

  # An `:httpc` profile of its own, so the proxy settings apply to this
  # download only, as in Mix's own downloader.
  @profile :ash_workflow_d2

  defp download!(url) do
    start_network_applications!()
    start_profile!()

    try do
      ssl = [
        ca_certificates(),
        verify: :verify_peer,
        depth: 3,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      request = {String.to_charlist(url), [{~c"user-agent", ~c"ash_workflow"}]}

      # `:timeout` limits the whole response. 10 minutes lets a slow link
      # finish the 16 to 18 MB tarball, and still ends a transfer that stops
      # part-way, which would otherwise hold the install lock for ever.
      http_opts = [ssl: ssl, timeout: 600_000, connect_timeout: 30_000] ++ proxy_options!()

      case :httpc.request(:get, request, http_opts, [body_format: :binary], @profile) do
        {:ok, {{_version, 200, _reason}, _headers, body}} ->
          body

        {:ok, {{_version, status, reason}, _headers, _body}} ->
          raise "the d2 download from #{url} failed with HTTP #{status} #{reason}"

        {:error, reason} ->
          raise "the d2 download from #{url} failed: #{inspect(reason)}"
      end
    after
      :inets.stop(:httpc, @profile)
    end
  end

  # `HEX_CACERTS_PATH` replaces the operating system's CA certificates, as in
  # Mix's own downloader, for a network that signs TLS with its own CA.
  defp ca_certificates do
    case System.get_env("HEX_CACERTS_PATH") do
      nil -> {:cacerts, :public_key.cacerts_get()}
      file -> {:cacertfile, String.to_charlist(file)}
    end
  end

  defp start_profile! do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # Under Mix, a project that does not list these applications may not have
  # them on its code path. `Mix.ensure_application!/1` adds them, as Mix's own
  # downloader does.
  defp start_network_applications! do
    apps = [:crypto, :public_key, :inets, :ssl]

    if mix_running?() do
      Enum.each(apps, &Mix.ensure_application!/1)
    end

    for app <- apps do
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          raise "the d2 download needs the #{inspect(app)} application, which did not start: " <>
                  "#{inspect(reason)}. In a release, set :path under config :ash_workflow, :d2."
      end
    end
  end

  # The same proxy variables as Mix, `esbuild` and `tailwind`. The tarball is
  # on HTTPS, so the HTTPS proxy sends its credentials; the HTTP proxy is set
  # for a redirect to a plain HTTP host.
  defp proxy_options! do
    no_proxy =
      case env(["NO_PROXY", "no_proxy"]) do
        nil ->
          []

        hosts ->
          hosts
          |> String.split(",", trim: true)
          |> Enum.map(&(&1 |> String.trim() |> String.to_charlist()))
      end

    https = proxy_uri(env(["HTTPS_PROXY", "https_proxy"]))
    http = proxy_uri(env(["HTTP_PROXY", "http_proxy"]))

    proxies =
      for {scheme, %URI{host: host, port: port}} <- [https_proxy: https, proxy: http],
          is_binary(host) and host != "",
          do: {scheme, {{String.to_charlist(host), port}, no_proxy}}

    :ok = :httpc.set_options(proxies, @profile)
    proxy_auth(https)
  end

  # An empty variable counts as not set, so it does not hide its other form.
  defp env(names) do
    Enum.find_value(names, fn name ->
      case System.get_env(name) do
        "" -> nil
        value -> value
      end
    end)
  end

  # `proxy.corp:3128`, with no scheme, is a proxy address too, as for curl.
  defp proxy_uri(nil), do: nil

  defp proxy_uri(proxy) do
    if String.contains?(proxy, "://"), do: URI.parse(proxy), else: URI.parse("http://" <> proxy)
  end

  defp proxy_auth(%URI{userinfo: userinfo}) when is_binary(userinfo) do
    [user, password] =
      case String.split(userinfo, ":", parts: 2) do
        [user, password] -> [user, password]
        [user] -> [user, ""]
      end

    [proxy_auth: {String.to_charlist(URI.decode(user)), String.to_charlist(URI.decode(password))}]
  end

  defp proxy_auth(_uri), do: []

  @doc """
  Runs `d2` on a diagram's source and returns `{:ok, svg, messages}`.

  `messages` are the other lines that `d2` printed, such as a warning, with
  no `success:` line. They are `""` when there are none.

  `args` are extra command-line arguments for `d2`, such as
  `["--pad", "20"]`. Downloads `d2` first when it is missing. When the source
  does not compile, returns `{:error, message}` with D2's own message.
  """
  @spec render_svg(iodata(), [String.t()]) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  def render_svg(source, args \\ []) do
    command = ensure_installed!()

    case Command.render_svg(command, "d2", source, &(args ++ [&1, &2]), env: clean_env()) do
      {:ok, svg, messages} -> {:ok, svg, drop_success(messages)}
      {:error, message} -> {:error, message}
    end
  end

  # `d2` prints all its messages to standard error. On exit 0 it prints
  # `success: successfully compiled ...`, which only reports the SVG, so
  # that line is not a message.
  defp drop_success(messages) do
    messages
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "success:"))
    |> Enum.join("\n")
    |> String.trim()
  end

  # The variables `d2` v0.9.0 reads that do not start with `D2_`. `HOST` and
  # `PORT` matter only in watch mode, which `D2_WATCH` turns on.
  @d2_variables ~w(BROWSER DEBUG HOST IMG_CACHE OMIT_VERSION PORT SCALE)

  # `d2` reads its environment before the file's `d2-config`, so an exported
  # `D2_THEME` would override the `:theme` option and `D2_WATCH` would make
  # `d2` serve the chart and never exit. `nil` removes a variable.
  defp clean_env do
    for {name, _value} <- System.get_env(),
        String.starts_with?(name, "D2_") or name in @d2_variables,
        do: {name, nil}
  end

  @doc """
  Like `render_svg/2`, but returns the SVG only, and raises `ArgumentError`
  when the source does not compile. When `d2` draws the SVG but prints a
  message, such as a warning, this function logs the message with
  `Logger.warning/1`.
  """
  @spec render_svg!(iodata(), [String.t()]) :: String.t()
  def render_svg!(source, args \\ []) do
    case render_svg(source, args) do
      {:ok, svg, ""} ->
        svg

      {:ok, svg, messages} ->
        Logger.warning("d2 printed a message while it drew the chart: #{messages}")
        svg

      {:error, message} ->
        raise ArgumentError, "d2 rejected the diagram: #{message}"
    end
  end

  @doc false
  # `config :ash_workflow, :d2`, which `AshWorkflow.Charts.D2` reads too.
  # `nil` is the same as no config. Any other value that is not a keyword
  # list raises here, with the name of the config.
  @spec config() :: keyword()
  def config do
    case Application.get_env(:ash_workflow, :d2) do
      nil ->
        []

      config ->
        if not Keyword.keyword?(config) do
          raise ArgumentError,
                "config :ash_workflow, :d2 must be a keyword list, such as " <>
                  ~S([theme: :dark, path: "/usr/local/bin/d2"], got: ) <> inspect(config)
        end

        config
    end
  end

  # A key set to `nil` counts as not set, so a runtime config can read a value
  # from a variable that may not be set.
  defp config(key), do: Keyword.get(config(), key)
end
