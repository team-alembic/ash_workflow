defmodule AshWorkflow.Charts.D2.BinaryTest do
  # `install!/0` and `render_svg/2` share one binary under `_build`, and the
  # config tests change the application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshWorkflow.Charts.D2
  alias AshWorkflow.Charts.D2.Binary
  alias AshWorkflow.Charts.Graph

  require Logger

  @targets ~w(linux-amd64 linux-arm64 macos-amd64 macos-arm64 windows-amd64 windows-arm64)

  test "target/0 names a platform D2 releases for" do
    assert Binary.target() in @targets
  end

  test "url/2 points at the release tarball" do
    assert Binary.url("0.9.0", "linux-amd64") ==
             "https://github.com/terrastruct/d2/releases/download/v0.9.0/d2-v0.9.0-linux-amd64.tar.gz"
  end

  test "path/0 is under _build, next to the build directory, with the platform in its name" do
    assert Binary.path() ==
             Path.join([
               Path.dirname(Mix.Project.build_path()),
               "d2-v0.9.0-#{Binary.target()}",
               "bin",
               "d2"
             ])
  end

  test "verify_checksum!/2 accepts the right sum and rejects a wrong one" do
    data = "hello"
    sum = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    assert Binary.verify_checksum!(data, sum) == :ok

    assert_raise ArgumentError, ~r/does not match its checksum/, fn ->
      Binary.verify_checksum!(data, String.duplicate("0", 64))
    end
  end

  @tag :d2
  test "ensure_installed!/0 downloads the binary once and then finds it" do
    path = Binary.ensure_installed!()

    assert path == Binary.path()
    assert File.regular?(path)
    assert Binary.installed?()
    assert {version, 0} = System.cmd(path, ["--version"])
    assert String.trim(version) == "v#{Binary.version()}"
  end

  @tag :d2
  test "render_svg/2 returns the SVG with no success line, or D2's message for a bad diagram" do
    assert {:ok, svg, ""} = Binary.render_svg(~S(a -> b: "hi"))
    assert svg =~ "<svg"
    assert svg =~ "hi"

    assert {:error, message} = Binary.render_svg("a -> : bad\n")
    assert message =~ "connection missing destination"
    refute message =~ "/ash_workflow_d2_"
  end

  @tag :d2
  test "render_svg/2 ignores the D2_* and other variables d2 reads" do
    previous = Map.new(["D2_LAYOUT", "SCALE"], &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, &restore_env/1) end)
    System.put_env("D2_LAYOUT", "no-such-layout")
    System.put_env("SCALE", "not-a-number")

    assert {:ok, svg, ""} = Binary.render_svg("a -> b\n")
    assert svg =~ "<svg"
  end

  @tag :d2
  test "render_svg!/2 raises for a bad diagram" do
    assert_raise ArgumentError,
                 ~r/d2 rejected the diagram: .*connection missing destination/,
                 fn ->
                   Binary.render_svg!("a -> : bad\n")
                 end
  end

  describe "with config :ash_workflow, :d2" do
    setup do
      previous = Application.get_env(:ash_workflow, :d2)
      on_exit(fn -> restore(previous) end)
      :ok
    end

    @tag :d2
    test ":path names a binary to run, and then there is nothing to install" do
      installed = Binary.ensure_installed!()
      Application.put_env(:ash_workflow, :d2, path: installed)

      assert Binary.path() == installed
      assert Binary.installed?()
      assert {:ok, _svg, ""} = Binary.render_svg("a -> b\n")
      assert_raise ArgumentError, ~r/nothing to install/, fn -> Binary.install!() end
    end

    test ":classes applies to every chart, and the option merges over it" do
      Application.put_env(:ash_workflow, :d2, classes: [failed: [fill: "#000000"]])
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      configured = graph |> D2.render([]) |> IO.iodata_to_binary()

      assert configured =~
               ~S(failed: {style: {fill: "#000000"; stroke: "#C81E1E"; double-border: true}})

      overridden =
        graph
        |> D2.render(classes: [failed: [stroke: "#FFFFFF"]])
        |> IO.iodata_to_binary()

      assert overridden =~
               ~S(failed: {style: {fill: "#000000"; stroke: "#FFFFFF"; double-border: true}})
    end

    test ":classes keyed by theme applies only the entry for the current theme" do
      Application.put_env(:ash_workflow, :d2,
        classes: [light: [manual: [fill: "#FFE4E6"]], dark: [manual: [fill: "#881337"]]]
      )

      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert graph |> D2.render([]) |> IO.iodata_to_binary() =~
               ~S(  manual: {style: {fill: "#FFE4E6"; stroke: "#B7791F"; border-radius: 4}})

      assert graph |> D2.render(theme: :dark) |> IO.iodata_to_binary() =~
               ~S(  manual: {style: {fill: "#881337"; stroke: "#FCD34D"; font-color: "#F8FAFC"; border-radius: 4}})
    end

    test "a nil :theme or :classes is the same as no key" do
      Application.put_env(:ash_workflow, :d2, theme: nil, classes: nil)
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert D2.theme() == :light

      assert graph |> D2.render(theme: nil, classes: nil) |> IO.iodata_to_binary() =~
               "theme-id: 0"
    end

    test ":theme sets the theme for every chart, and the option overrides it" do
      Application.put_env(:ash_workflow, :d2, theme: :dark)
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert D2.theme() == :dark
      assert D2.theme(theme: :light) == :light
      assert graph |> D2.render([]) |> IO.iodata_to_binary() =~ "theme-id: 200"
      assert graph |> D2.render(theme: :light) |> IO.iodata_to_binary() =~ "theme-id: 0"
    end

    test "a key set to nil is the same as no key" do
      Application.put_env(:ash_workflow, :d2, path: nil, version: nil, checksums: nil)

      assert Binary.version() == "0.9.0"
      assert Binary.path() =~ "d2-v0.9.0-#{Binary.target()}"
      assert Binary.installed?() == File.regular?(Binary.path())
    end

    test "an empty :path is the same as no :path" do
      Application.put_env(:ash_workflow, :d2, path: "")

      assert Binary.path() =~ "d2-v0.9.0-#{Binary.target()}"
      assert Binary.installed?() == File.regular?(Binary.path())
    end

    test "a :path that is not a string raises" do
      for path <- [false, ~c"/usr/local/bin/d2", :d2] do
        Application.put_env(:ash_workflow, :d2, path: path)

        assert_raise ArgumentError,
                     "config :ash_workflow, :d2, path: must be a string, got: #{inspect(path)}",
                     fn -> Binary.ensure_installed!() end
      end
    end

    test "a :d2 config that is not a keyword list raises and names the config" do
      Application.put_env(:ash_workflow, :d2, "/usr/local/bin/d2")

      message =
        ~S(config :ash_workflow, :d2 must be a keyword list, such as [theme: :dark, path: "/usr/local/bin/d2"], got: "/usr/local/bin/d2")

      assert_raise ArgumentError, message, fn -> D2.theme() end
      assert_raise ArgumentError, message, fn -> Binary.ensure_installed!() end
    end

    test "a nil :d2 config is the same as no config" do
      Application.put_env(:ash_workflow, :d2, nil)

      assert D2.theme() == :light
      assert Binary.version() == "0.9.0"
      assert Binary.path() =~ "d2-v0.9.0-#{Binary.target()}"
    end

    @tag :tmp_dir
    test "a :path that starts with ~ is in the home directory", %{tmp_dir: dir} do
      script = script!(dir, "d2", "exit 0")
      home_relative = Path.relative_to(script, System.user_home!(), force: true)
      Application.put_env(:ash_workflow, :d2, path: "~/" <> home_relative)

      assert Binary.ensure_installed!() == script
    end

    @tag :tmp_dir
    test "a relative :path to a file is made absolute, as System.cmd/3 looks for it on the PATH",
         %{tmp_dir: dir} do
      script = script!(dir, "d2", "exit 0")
      Application.put_env(:ash_workflow, :d2, path: Path.relative_to_cwd(script))

      assert Binary.installed?()
      assert Binary.ensure_installed!() == script
    end

    test "a :path with no / is a command on the PATH, not a file in the current directory" do
      Application.put_env(:ash_workflow, :d2, path: "mix.exs")

      refute Binary.installed?()

      assert_raise ArgumentError, ~r/neither an executable file nor a command on the PATH/, fn ->
        Binary.ensure_installed!()
      end
    end

    test "a :path to a file that is not executable names no d2" do
      Application.put_env(:ash_workflow, :d2, path: "./mix.exs")

      refute Binary.installed?()

      assert_raise ArgumentError, ~r/neither an executable file nor a command on the PATH/, fn ->
        Binary.ensure_installed!()
      end
    end

    @tag :tmp_dir
    test "a d2 that fails and prints nothing gets a message with its exit status",
         %{tmp_dir: dir} do
      silent = script!(dir, "silent", "exit 3")
      Application.put_env(:ash_workflow, :d2, path: silent)

      assert Binary.render_svg("a -> b\n") ==
               {:error, "#{silent} exited with status 3 and printed nothing"}
    end

    test ":path may name a command on the PATH" do
      Application.put_env(:ash_workflow, :d2, path: "sh")

      assert Binary.installed?()
      assert Binary.ensure_installed!() == System.find_executable("sh")
    end

    test "a :path that is neither an executable file nor a command raises" do
      Application.put_env(:ash_workflow, :d2, path: "no-such-d2-command")

      refute Binary.installed?()

      assert_raise ArgumentError,
                   ~r/sets :path to "no-such-d2-command", which is neither an executable file nor a command on the PATH/,
                   fn -> Binary.ensure_installed!() end
    end

    test "a version without a known checksum needs :checksums" do
      Application.put_env(:ash_workflow, :d2, version: "0.0.1")

      assert Binary.version() == "0.0.1"
      assert Binary.path() =~ "d2-v0.0.1"

      assert_raise ArgumentError,
                   ~r/no checksum for d2 v0.0.1 on #{Binary.target()}. Set "#{Binary.target()}" in :checksums/,
                   fn -> Binary.install!() end
    end

    test ":checksums gives the sum for each platform of a version that is not pinned" do
      Application.put_env(:ash_workflow, :d2,
        checksums: %{"linux-amd64" => "  ABC123\n", "macos-arm64" => "def456"}
      )

      assert Binary.expected_checksum!("0.0.1", "linux-amd64") == "abc123"
      assert Binary.expected_checksum!("0.0.1", "macos-arm64") == "def456"

      assert_raise ArgumentError,
                   ~r/no checksum for d2 v0.0.1 on windows-amd64. Set "windows-amd64" in :checksums/,
                   fn -> Binary.expected_checksum!("0.0.1", "windows-amd64") end
    end

    test "the pinned version ignores :checksums" do
      Application.put_env(:ash_workflow, :d2, checksums: %{"linux-amd64" => "abc123"})

      assert Binary.expected_checksum!("0.9.0", "linux-amd64") ==
               "5669ddc46b99e942cc96078f4a4e36d5e62103348f4c05179ede27802fdd87a9"
    end
  end

  describe "a message from a d2 that draws the chart" do
    # The test config logs only critical messages.
    setup do
      previous = Application.get_env(:ash_workflow, :d2)
      Logger.put_module_level(Binary, :warning)

      on_exit(fn ->
        Logger.delete_module_level(Binary)
        restore(previous)
      end)
    end

    @tag :tmp_dir
    test "goes to the log, with no success line", %{tmp_dir: dir} do
      # `d2 <input> <output>`, so the output file is `$2`. d2 prints a warning
      # as `warn: ...`, and on exit 0 it prints `success: ...`.
      warning =
        script!(dir, "d2", ~S"""
        echo '<svg/>' > "$2"
        echo 'warn: Invalid DEBUG flag value ignored' >&2
        echo "success: successfully compiled $1 to $2 in 1ms" >&2
        """)

      Application.put_env(:ash_workflow, :d2, path: warning)

      assert Binary.render_svg("a -> b\n") ==
               {:ok, "<svg/>\n", "warn: Invalid DEBUG flag value ignored"}

      log = capture_log(fn -> assert Binary.render_svg!("a -> b\n") == "<svg/>\n" end)

      assert log =~
               "d2 printed a message while it drew the chart: warn: Invalid DEBUG flag value ignored"

      refute log =~ "success:"
    end
  end

  test "with MIX_BUILD_PATH set, d2 goes inside that build directory" do
    previous = System.get_env("MIX_BUILD_PATH")
    on_exit(fn -> restore_env({"MIX_BUILD_PATH", previous}) end)
    System.put_env("MIX_BUILD_PATH", "/tmp/ash_workflow_build")

    assert Binary.path() == "/tmp/ash_workflow_build/d2-v0.9.0-#{Binary.target()}/bin/d2"
  end

  # An executable shell script with the given body.
  defp script!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)

  defp restore(nil), do: Application.delete_env(:ash_workflow, :d2)
  defp restore(previous), do: Application.put_env(:ash_workflow, :d2, previous)
end
