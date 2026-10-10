defmodule AshWorkflow.Charts.Command do
  @moduledoc false
  # Runs a command that reads a diagram from a file and writes an SVG to a
  # file, such as `dot`. Each backend that draws an SVG with a command uses
  # it, so the temporary files and the messages work the same in each.

  @doc """
  The command for a configured `:path`, as an absolute path, or `nil` when
  there is none.

  A name with no `/`, such as `"dot"`, is a command on the `PATH`. A path
  with a `/`, or one that starts with `~`, is a file, relative to the
  current directory. `System.find_executable/1` finds both, so the command
  must be a regular file with the execute bit set.

  `System.cmd/3` looks for a name that is not absolute on the `PATH` only, so
  the result is made absolute. Otherwise `"bin/dot"`, or a relative entry in
  the `PATH`, gives a command that does not run, and `"./dot"` runs another
  `dot` from the `PATH`. `Path.expand/1` also expands `~`.
  """
  @spec find(String.t()) :: Path.t() | nil
  def find(path) do
    found =
      if String.contains?(path, "/") or String.starts_with?(path, "~"),
        do: System.find_executable(Path.expand(path)),
        else: System.find_executable(path)

    found && Path.expand(found)
  end

  @doc """
  A name that is unique across OS processes, not only within this VM,
  because two `mix` processes can share `_build` and the temporary
  directory. The random part makes the name hard to guess.
  """
  @spec unique_name() :: String.t()
  def unique_name do
    "#{System.pid()}-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
  end

  @doc """
  Writes `source` to a temporary `.<extension>` file, runs `command` with the
  arguments that `args` gives for the input and the output file, and returns
  `{:ok, svg, messages}`: the SVG from the output file, and the messages
  that the command printed, such as a warning. The messages are trimmed,
  with "diagram" in place of the path of the input file, and are `""` when
  there are none.

  When the command exits with a status other than 0, returns
  `{:error, message}` with the command's messages. A command that prints
  nothing, such as a binary for another platform, gets a message with its
  exit status. A command that exits with status 0 and writes no SVG gets a
  message that says so, followed by its messages. Both files are removed.

  Options:

  * `:env` — the environment changes for the command, as for `System.cmd/3`.
    A `nil` value removes a variable.
  """
  @spec render_svg(
          Path.t(),
          String.t(),
          iodata(),
          (Path.t(), Path.t() -> [String.t()]),
          keyword()
        ) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def render_svg(command, extension, source, args, opts \\ []) do
    base = Path.join(System.tmp_dir!(), "ash_workflow_#{extension}_#{unique_name()}")
    input = base <> "." <> extension
    output = base <> ".svg"
    File.write!(input, source)

    # The command writes its messages to stderr, and a port cannot keep
    # stderr apart from stdout, so the SVG goes to a file and the messages
    # come back as the command output.
    try do
      {messages, status} =
        System.cmd(command, args.(input, output),
          stderr_to_stdout: true,
          env: Keyword.get(opts, :env, [])
        )

      messages = messages |> String.replace(input, "diagram") |> String.trim()

      case {status, File.read(output)} do
        {0, {:ok, svg}} -> {:ok, svg, messages}
        {0, {:error, _reason}} -> {:error, no_svg_message(messages, command)}
        {status, _output} -> {:error, error_message(messages, command, status)}
      end
    after
      File.rm(input)
      File.rm(output)
    end
  end

  defp no_svg_message("", command), do: "#{command} exited with status 0 and wrote no SVG"
  defp no_svg_message(messages, command), do: no_svg_message("", command) <> ": " <> messages

  # A binary that cannot run, such as one for another platform, prints
  # nothing. Say so, rather than return an empty message.
  defp error_message("", command, status),
    do: "#{command} exited with status #{status} and printed nothing"

  defp error_message(messages, _command, _status), do: messages
end
