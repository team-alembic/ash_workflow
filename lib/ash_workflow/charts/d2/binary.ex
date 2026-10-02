defmodule AshWorkflow.Charts.D2.Binary do
  @moduledoc """
  Downloads the `d2` command and runs it, so `AshWorkflow.Charts.D2` can give
  you an SVG with no tool to install first.

  D2 is a Go program, and no Hex package wraps it. This module works the way
  the `esbuild` and `tailwind` packages do:

  1. The first time you ask for an SVG, it downloads the `d2` release for
     your platform from GitHub.
  2. It checks the download against the SHA-256 that ships with the release.
  3. It unpacks `d2` into `_build/d2-v<version>/bin/d2`, beside the project's
     build directory, and keeps it there.
  4. It runs `d2` as an external process for each SVG.

  You usually need nothing from this module directly. Call
  `AshWorkflow.Charts.render(resource, :d2, svg: true)`, and it does the rest.

  ## Configuration

      config :ash_workflow, :d2,
        version: "0.9.0",
        path: "/usr/local/bin/d2"

  * `:path` — a `d2` you installed yourself: a file path, or a command name
    such as `"d2"` that is on the `PATH`. When it is set, nothing is
    downloaded.
  * `:version` — the release to download. Defaults to the release this
    library pins, which is the only one it has checksums for.
  * `:checksum` — the SHA-256 of the tarball, as hex, for a `:version` that
    this library does not pin. Case and surrounding whitespace do not matter.

  ## Continuous integration

  `mix ash_workflow.d2.install` downloads `d2` ahead of time. Run it in a
  step that has network access, before the tests run. A CI cache of `_build`
  keeps the binary between runs.

  ## Releases

  `mix release` does not copy `_build/d2-v<version>`. So a release cannot
  use a `d2` that was downloaded at build time. Install `d2` on the host, or
  copy it into the release, and set `:path` to it in `config/runtime.exs`.
  Without `:path`, the first `svg: true` call in a release tries to download
  `d2` into the release's working directory.

  ## Network

  The download uses `:httpc` and checks the server's certificate against the
  operating system's CA certificates. It reads `HTTPS_PROXY` and
  `HTTP_PROXY`, and their lowercase forms. It needs the `:crypto`,
  `:public_key`, `:inets` and `:ssl` applications. This library lists them as
  optional, so a release includes them when the host has them.
  """

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
  def version, do: Keyword.get(config(), :version, @default_version)

  @doc """
  The platform part of the tarball name for this machine, such as
  `"macos-arm64"`.

  Raises `ArgumentError` on a platform D2 has no release for.
  """
  @spec target() :: String.t()
  def target do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    case {:os.type(), arch} do
      {{:win32, _}, _} -> "windows-" <> windows_arch()
      {{:unix, :darwin}, "aarch64" <> _} -> "macos-arm64"
      {{:unix, :darwin}, "x86_64" <> _} -> "macos-amd64"
      {{:unix, :linux}, "aarch64" <> _} -> "linux-arm64"
      {{:unix, :linux}, "x86_64" <> _} -> "linux-amd64"
      {os, _} -> raise ArgumentError, "d2 has no release for #{inspect(os)} on #{arch}"
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
    case Keyword.fetch(config(), :path) do
      {:ok, path} -> path
      :error -> download_path()
    end
  end

  defp download_path, do: Path.join([base_dir(), "d2-v#{version()}", "bin", executable_name()])

  # A configured `:path` is a file, or a command that `System.find_executable/1`
  # finds on the `PATH`, the same lookup `System.cmd/3` makes.
  defp configured_executable(path) do
    if File.regular?(path), do: path, else: System.find_executable(path)
  end

  defp executable_name do
    case :os.type() do
      {:win32, _} -> "d2.exe"
      _ -> "d2"
    end
  end

  # `_build` next to the project's build directory under Mix, so the binary
  # sits with the compiled code and a CI cache of `_build` keeps it. Outside
  # Mix, `_build` under the current directory.
  defp base_dir do
    if Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :build_path, 0) do
      Mix.Project.build_path() |> Path.dirname()
    else
      Path.join(File.cwd!(), "_build")
    end
  end

  @doc """
  Whether the binary is there: the configured `:path` names a file or a
  command on the `PATH`, or the download is at `path/0`.
  """
  @spec installed?() :: boolean()
  def installed? do
    case Keyword.fetch(config(), :path) do
      {:ok, path} -> configured_executable(path) != nil
      :error -> File.regular?(download_path())
    end
  end

  @doc """
  The path of the binary to run, after a download when it is missing.

  Raises `ArgumentError` when `:path` is configured and names neither a file
  nor a command on the `PATH`.
  """
  @spec ensure_installed!() :: Path.t()
  def ensure_installed! do
    case Keyword.fetch(config(), :path) do
      {:ok, path} ->
        configured_executable(path) ||
          raise ArgumentError,
                "config :ash_workflow, :d2 sets :path to #{inspect(path)}, " <>
                  "which is neither a file nor a command on the PATH"

      :error ->
        if File.regular?(download_path()), do: download_path(), else: install!()
    end
  end

  @doc """
  Downloads the release tarball, checks its SHA-256, and unpacks `d2` to
  `path/0`. Returns that path.

  Raises when the platform has no release, when the version has no known
  checksum and `:checksum` is not configured, when the sum does not match, or
  when the download fails.
  """
  @spec install!() :: Path.t()
  def install! do
    if Keyword.has_key?(config(), :path) do
      raise ArgumentError,
            "config :ash_workflow, :d2 sets :path to #{inspect(path())}, so there is nothing to install"
    end

    version = version()
    target = target()
    url = url(version, target)
    expected = expected_checksum!(version, target)
    dir = Path.join(base_dir(), "d2-v#{version}")

    Logger.info("Downloading d2 v#{version} for #{target} from #{url}")
    tarball = download!(url)
    verify_checksum!(tarball, expected)

    # Unpack beside the final directory and move it into place in one step,
    # so two processes that install at the same time cannot see a half-written
    # binary. The second move finds the directory there, and the first install
    # wins. The staging directory goes on every path out, so a failed extract
    # leaves nothing in `_build`.
    staging = "#{dir}.tmp-#{unique_name()}"

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

  # Unique across OS processes, not only within this VM, because two `mix`
  # processes can share `_build` and the temporary directory.
  defp unique_name do
    "#{System.pid()}-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
  end

  defp expected_checksum!(version, target) do
    case Keyword.fetch(config(), :checksum) do
      {:ok, checksum} ->
        checksum |> String.trim() |> String.downcase()

      :error ->
        get_in(@checksums, [version, target]) ||
          raise ArgumentError,
                "ash_workflow has no checksum for d2 v#{version} on #{target}. " <>
                  "Set :checksum under config :ash_workflow, :d2, or use version #{@default_version}."
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

  defp download!(url) do
    start_network_applications!()
    set_proxy()

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    request = {String.to_charlist(url), [{~c"user-agent", ~c"ash_workflow"}]}
    http_opts = [ssl: ssl, timeout: 120_000, connect_timeout: 30_000]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        body

      {:ok, {{_version, status, reason}, _headers, _body}} ->
        raise "the d2 download from #{url} failed with HTTP #{status} #{reason}"

      {:error, reason} ->
        raise "the d2 download from #{url} failed: #{inspect(reason)}"
    end
  end

  defp start_network_applications! do
    for app <- [:crypto, :public_key, :inets, :ssl] do
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          raise "the d2 download needs the #{inspect(app)} application, which did not start: " <>
                  "#{inspect(reason)}. In a release, set :path under config :ash_workflow, :d2."
      end
    end
  end

  # The same proxy variables `esbuild` and `tailwind` read. `:httpc` takes one
  # proxy per scheme, for the default profile.
  defp set_proxy do
    for {scheme, names} <- [
          https_proxy: ["HTTPS_PROXY", "https_proxy"],
          proxy: ["HTTP_PROXY", "http_proxy"]
        ],
        proxy = Enum.find_value(names, &System.get_env/1),
        %URI{host: host, port: port} when is_binary(host) <- [URI.parse(proxy)] do
      :httpc.set_options([{scheme, {{String.to_charlist(host), port}, []}}])
    end
  end

  @doc """
  Runs `d2` on a diagram's source and returns the SVG.

  `args` are extra command-line arguments for `d2`, such as
  `["--pad", "20"]`. Downloads `d2` first when it is missing. When the source
  does not compile, returns `{:error, message}` with D2's own message.
  """
  @spec render_svg(iodata(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def render_svg(source, args \\ []) do
    binary = ensure_installed!()
    base = Path.join(System.tmp_dir!(), "ash_workflow_d2_#{unique_name()}")
    input = base <> ".d2"
    output = base <> ".svg"
    File.write!(input, source)

    # D2 writes its messages to stderr, and a port cannot keep stderr apart
    # from stdout, so the SVG goes to a file and the messages come back as
    # the command output.
    try do
      case System.cmd(binary, args ++ [input, output], stderr_to_stdout: true) do
        {_messages, 0} ->
          {:ok, File.read!(output)}

        {messages, _status} ->
          {:error, messages |> String.replace(input, "diagram") |> String.trim()}
      end
    after
      File.rm(input)
      File.rm(output)
    end
  end

  @doc """
  Like `render_svg/2`, but raises `ArgumentError` when the source does not
  compile.
  """
  @spec render_svg!(iodata(), [String.t()]) :: String.t()
  def render_svg!(source, args \\ []) do
    case render_svg(source, args) do
      {:ok, svg} -> svg
      {:error, message} -> raise ArgumentError, "d2 rejected the diagram: #{message}"
    end
  end

  defp config, do: Application.get_env(:ash_workflow, :d2, [])
end
