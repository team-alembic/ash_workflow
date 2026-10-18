defmodule AshWorkflow.RecipeCase do
  @moduledoc """
  Runs an Igniter task against fixture files, compiles what it generated, and
  returns the compiled modules for the test to drive through Ash.

  Compiled modules are renamed under a namespace unique to the test, so tests
  stay `async: true` and never redefine a loaded fixture. Look them up in
  `modules` by the name the task gave them.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  defstruct [:igniter, :changed, notices: [], warnings: [], modules: %{}]

  @type t :: %__MODULE__{
          igniter: Igniter.t(),
          changed: %{String.t() => String.t()},
          notices: [String.t()],
          warnings: [String.t()],
          modules: %{module() => module()}
        }

  using do
    quote do
      import AshWorkflow.RecipeCase

      @moduletag :igniter
      @moduletag :tmp_dir
    end
  end

  @doc "Builds a test project containing the given fixture files, read from disk."
  @spec project([Path.t()]) :: Igniter.t()
  def project(paths) do
    Igniter.Test.test_project(
      app_name: :ash_workflow,
      files: Map.new(paths, &{&1, File.read!(&1)})
    )
  end

  @doc """
  Composes `task` with `argv`, applies it, and asserts it reported no issues.
  """
  @spec run_task(Igniter.t(), String.t(), [String.t()]) :: t()
  def run_task(igniter, task, argv) do
    before = igniter.assigns.test_files

    case igniter |> Igniter.compose_task(task, argv) |> Igniter.Test.apply_igniter() do
      {:ok, applied, %{notices: notices, warnings: warnings}} ->
        %__MODULE__{
          igniter: applied,
          changed: changed_files(before, applied.assigns.test_files),
          notices: notices,
          warnings: warnings
        }

      {:error, issues} ->
        flunk("#{task} reported issues:\n\n" <> Enum.join(issues, "\n\n"))
    end
  end

  @doc """
  Writes every `.ex` file the task created or changed into `tmp_dir` and
  compiles them, failing on any error or warning.
  """
  @spec compile(t(), Path.t()) :: t()
  def compile(%__MODULE__{changed: changed} = recipe, tmp_dir) do
    namespace = "RecipeRun#{System.unique_integer([:positive])}"

    renames =
      changed
      |> Map.values()
      |> Enum.flat_map(&defined_modules/1)
      |> Map.new(&{&1, Module.concat([namespace | Module.split(&1)])})

    files =
      Enum.map(changed, fn {path, content} ->
        file = Path.join(tmp_dir, path)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, rename_modules(content, renames))
        file
      end)

    {result, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Kernel.ParallelCompiler.compile(files, return_diagnostics: true)
      end)

    case result do
      {:ok, _modules, diagnostics} ->
        assert warnings(diagnostics) == []
        %{recipe | modules: renames}

      {:error, errors, diagnostics} ->
        flunk(
          "generated code failed to compile:\n\n" <>
            Enum.map_join(errors ++ warnings(diagnostics), "\n\n", & &1.message)
        )
    end
  end

  @doc "Returns the content of `path` after the task ran."
  @spec source!(t(), Path.t()) :: String.t()
  def source!(%__MODULE__{igniter: igniter}, path) do
    Map.fetch!(igniter.assigns.test_files, path)
  end

  # The test build consolidates protocols, so every resource compiled at
  # runtime warns that its derived `Inspect` implementation has no effect.
  defp warnings(diagnostics) do
    Enum.reject(
      diagnostics.compile_warnings ++ diagnostics.runtime_warnings,
      &(&1.message =~ "protocol has already been consolidated")
    )
  end

  defp changed_files(before, after_task) do
    for {path, content} <- after_task,
        Path.extname(path) == ".ex",
        Map.get(before, path) != content,
        into: %{},
        do: {path, content}
  end

  defp defined_modules(content) do
    {_ast, modules} =
      content
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    modules
  end

  defp rename_modules(content, renames) do
    Enum.reduce(renames, content, fn {from, to}, content ->
      String.replace(content, ~r/(?<![\w.])#{Regex.escape(inspect(from))}(?!\w)/, inspect(to))
    end)
  end
end
