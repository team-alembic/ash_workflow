defmodule AshWorkflow.Charts.D2.BinaryTest do
  # `install!/0` and `render_svg/2` share one binary under `_build`, and the
  # config tests change the application environment.
  use ExUnit.Case, async: false

  alias AshWorkflow.Charts.D2
  alias AshWorkflow.Charts.D2.Binary
  alias AshWorkflow.Charts.Graph

  @targets ~w(linux-amd64 linux-arm64 macos-amd64 macos-arm64 windows-amd64 windows-arm64)

  test "target/0 names a platform D2 releases for" do
    assert Binary.target() in @targets
  end

  test "url/2 points at the release tarball" do
    assert Binary.url("0.9.0", "linux-amd64") ==
             "https://github.com/terrastruct/d2/releases/download/v0.9.0/d2-v0.9.0-linux-amd64.tar.gz"
  end

  test "path/0 is under _build, next to the build directory" do
    assert Binary.path() ==
             Path.join([Path.dirname(Mix.Project.build_path()), "d2-v0.9.0", "bin", "d2"])
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
  test "render_svg/2 returns the SVG, or D2's message for a bad diagram" do
    assert {:ok, svg} = Binary.render_svg(~S(a -> b: "hi"))
    assert svg =~ "<svg"
    assert svg =~ "hi"

    assert {:error, message} = Binary.render_svg("a -> : bad\n")
    assert message =~ "connection missing destination"
    refute message =~ "/ash_workflow_d2_"
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
      assert {:ok, _svg} = Binary.render_svg("a -> b\n")
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

    test ":theme sets the theme for every chart, and the option overrides it" do
      Application.put_env(:ash_workflow, :d2, theme: :dark)
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert graph |> D2.render([]) |> IO.iodata_to_binary() =~ "theme-id: 200"
      assert graph |> D2.render(theme: :light) |> IO.iodata_to_binary() =~ "theme-id: 0"
    end

    test ":path may name a command on the PATH" do
      Application.put_env(:ash_workflow, :d2, path: "sh")

      assert Binary.installed?()
      assert Binary.ensure_installed!() == System.find_executable("sh")
    end

    test "a :path that is neither a file nor a command raises" do
      Application.put_env(:ash_workflow, :d2, path: "no-such-d2-command")

      refute Binary.installed?()

      assert_raise ArgumentError, ~r/neither a file nor a command on the PATH/, fn ->
        Binary.ensure_installed!()
      end
    end

    test "a version without a known checksum needs :checksum" do
      Application.put_env(:ash_workflow, :d2, version: "0.0.1")

      assert Binary.version() == "0.0.1"
      assert Binary.path() =~ "d2-v0.0.1"
      assert_raise ArgumentError, ~r/no checksum for d2 v0.0.1/, fn -> Binary.install!() end
    end
  end

  defp restore(nil), do: Application.delete_env(:ash_workflow, :d2)
  defp restore(previous), do: Application.put_env(:ash_workflow, :d2, previous)
end
