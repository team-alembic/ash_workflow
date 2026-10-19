defmodule AshWorkflow.Charts.Command do
  @moduledoc false
  # Runs a command, such as `dot`, that reads a diagram from a file and
  # writes an SVG to a file. The backends share it, so they handle the
  # temporary files and the messages in the same way.

  @doc """
  The command for a configured `:path`, as an absolute path, or `nil` when
  there is none.

  A name with no `/`, such as `"dot"`, is a command on the `PATH`. A path
  with a `/`, or one that starts with `~`, is a file, relative to the
  current directory. Either must be a regular file with the execute bit set.

  The result is absolute because `System.cmd/3` looks up any other name on
  the `PATH`. So `"bin/dot"`, or a `dot` in a relative `PATH` entry, would
  not run, and `"./dot"` would run another `dot` from the `PATH`.
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
  A name that is unique across OS processes, because two `mix` processes can
  share `_build` and the temporary directory. The random part makes it hard
  to guess.
  """
  @spec unique_name() :: String.t()
  def unique_name do
    "#{System.pid()}-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
  end

  @doc """
  Writes `source` to a temporary `.<extension>` file, runs `command` with
  `args.(input, output)`, and returns `{:ok, svg, messages}`. The messages
  are what the command printed, such as a warning: trimmed, with "diagram"
  in place of the input path, and `""` when there are none.

  Returns `{:error, message}` when the command exits with a status other
  than 0. The message is what the command printed, or its exit status when
  it printed nothing, such as a binary for another platform. A command that
  exits with 0 and writes no SVG also gives an error. Both files are removed.

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
  # nothing, so the message gives the exit status.
  defp error_message("", command, status),
    do: "#{command} exited with status #{status} and printed nothing"

  defp error_message(messages, _command, _status), do: messages
end
