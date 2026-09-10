defmodule AshWorkflowTest.DslAssertions do
  @moduledoc """
  Helper for asserting that a workflow is rejected at compile time.

  Spark reports verifier failures from `__after_verify__`. Depending on how the
  module is being compiled that surfaces either as a raised
  `Spark.Error.DslError` or as a compiler diagnostic, so tests assert on the
  message rather than on the delivery mechanism.
  """

  import ExUnit.Assertions

  @doc """
  Compiles `code` and asserts the compilation is rejected with a message
  matching `pattern`.
  """
  def assert_dsl_error(code, pattern) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(code)
          :compiled
        rescue
          error -> {:raised, Exception.message(error)}
        end
      end)

    messages =
      case result do
        {:raised, message} -> [message]
        :compiled -> Enum.map(diagnostics, &to_string(&1.message))
      end

    assert Enum.any?(messages, &Regex.match?(pattern, &1)), """
    Expected compiling the workflow to be rejected with a message matching:

        #{inspect(pattern)}

    Messages produced:

    #{Enum.map_join(messages, "\n", &"  - #{String.slice(&1, 0, 400)}")}
    """
  end

  @doc """
  Compiles `code` and asserts nothing rejected it.

  The counterpart to `assert_dsl_error/2`, for the configuration a new verifier
  has to keep accepting.
  """
  def assert_dsl_compiles(code) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(code)
          :compiled
        rescue
          error -> {:raised, Exception.message(error)}
        end
      end)

    errors =
      case result do
        {:raised, message} ->
          [message]

        :compiled ->
          diagnostics
          |> Enum.filter(&(&1.severity == :error))
          |> Enum.map(&to_string(&1.message))
      end

    assert errors == [], """
    Expected the workflow to compile, but it was rejected:

    #{Enum.map_join(errors, "\n", &"  - #{String.slice(&1, 0, 400)}")}
    """
  end
end
