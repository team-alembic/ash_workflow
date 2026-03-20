defmodule AshWorkflow.Verifiers.ValidateWorkflowTest do
  @moduledoc """
  Tests the workflow verifier by calling it directly with mock DSL state.

  We build a minimal map that satisfies `Verifier.get_entities(dsl, [:workflow])`
  and call `ValidateWorkflow.verify/1` directly.
  """
  use ExUnit.Case

  alias AshWorkflow.Entities.{Step, Transition, Timeout}
  alias AshWorkflow.Verifiers.ValidateWorkflow

  defp build_dsl(steps) do
    %{
      [:workflow] => %{entities: steps}
    }
  end

  defp step(name, opts \\ []) do
    %Step{
      name: name,
      action: opts[:action],
      manual: opts[:manual] || false,
      terminal: opts[:terminal] || false,
      on_success: opts[:on_success],
      on_error: opts[:on_error],
      policy: opts[:policy],
      transitions: opts[:transitions] || [],
      timeouts: opts[:timeouts] || []
    }
  end

  defp transition(name, to) do
    %Transition{name: name, to: to}
  end

  defp timeout(name, opts) do
    %Timeout{
      name: name,
      after: opts[:after] || {1, :days},
      action: opts[:action],
      transition_to: opts[:transition_to],
      repeat: opts[:repeat] || false
    }
  end

  describe "valid workflows" do
    test "minimal automatic + terminal" do
      dsl =
        build_dsl([
          step(:process, action: :do_work, on_success: :done),
          step(:done, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end

    test "manual step with transitions" do
      dsl =
        build_dsl([
          step(:review,
            manual: true,
            transitions: [transition(:approve, :done), transition(:reject, :rejected)]
          ),
          step(:done, terminal: true),
          step(:rejected, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end

    test "auto → manual → terminal chain" do
      dsl =
        build_dsl([
          step(:intake, action: :run_intake, on_success: :review),
          step(:review, manual: true, transitions: [transition(:approve, :done)]),
          step(:done, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end

    test "step with timeouts" do
      dsl =
        build_dsl([
          step(:waiting,
            manual: true,
            transitions: [transition(:resolve, :done)],
            timeouts: [
              timeout(:reminder, action: :send_reminder),
              timeout(:escalation, transition_to: :escalated)
            ]
          ),
          step(:done, terminal: true),
          step(:escalated, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end
  end

  describe "step config validation" do
    test "automatic step without on_success fails" do
      dsl =
        build_dsl([
          step(:broken, action: :something),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must have on_success"
    end

    test "automatic step without action fails" do
      dsl =
        build_dsl([
          step(:broken, on_success: :done),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must have an action"
    end

    test "manual step without transitions fails" do
      dsl =
        build_dsl([
          step(:waiting, manual: true),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must have at least one transition"
    end

    test "manual step with action fails" do
      dsl =
        build_dsl([
          step(:review, manual: true, action: :something, transitions: [transition(:go, :done)]),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must not have an action"
    end

    test "manual step with on_success fails" do
      dsl =
        build_dsl([
          step(:review, manual: true, on_success: :done, transitions: [transition(:go, :done)]),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must not have on_success"
    end

    test "automatic step with transitions fails" do
      dsl =
        build_dsl([
          step(:auto, action: :run, on_success: :done, transitions: [transition(:go, :done)]),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must not have transitions"
    end

    test "terminal step with action fails" do
      dsl =
        build_dsl([
          step(:start, action: :go, on_success: :done),
          step(:done, terminal: true, action: :cleanup)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "Terminal step :done must not have an action"
    end

    test "terminal step with transitions fails" do
      dsl =
        build_dsl([
          step(:start, manual: true, transitions: [transition(:go, :done)]),
          step(:done, terminal: true, transitions: [transition(:oops, :start)])
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "Terminal step :done must not have transitions"
    end

    test "terminal step with on_success fails" do
      dsl =
        build_dsl([
          step(:start, action: :go, on_success: :done),
          step(:done, terminal: true, on_success: :start)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "Terminal step :done must not have on_success"
    end

    test "terminal step with timeouts fails" do
      dsl =
        build_dsl([
          step(:start, action: :go, on_success: :done),
          step(:done, terminal: true, timeouts: [timeout(:nag, action: :nag)])
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "Terminal step :done must not have timeouts"
    end
  end

  describe "timeout validation" do
    test "timeout without action or transition_to fails" do
      dsl =
        build_dsl([
          step(:waiting,
            manual: true,
            transitions: [transition(:go, :done)],
            timeouts: [timeout(:broken, [])]
          ),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must have either action or transition_to"
    end

    test "timeout with both action and transition_to fails" do
      dsl =
        build_dsl([
          step(:waiting,
            manual: true,
            transitions: [transition(:go, :done)],
            timeouts: [timeout(:broken, action: :remind, transition_to: :escalated)]
          ),
          step(:done, terminal: true),
          step(:escalated, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must have either action or transition_to, not both"
    end
  end

  describe "reference validation" do
    test "dangling on_success reference fails" do
      dsl =
        build_dsl([
          step(:start, action: :go, on_success: :nonexistent)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "references unknown step :nonexistent"
    end

    test "dangling on_error reference fails" do
      dsl =
        build_dsl([
          step(:start, action: :go, on_success: :done, on_error: :nonexistent),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "references unknown step :nonexistent"
    end

    test "dangling transition reference fails" do
      dsl =
        build_dsl([
          step(:waiting, manual: true, transitions: [transition(:go, :nowhere)])
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "references unknown step :nowhere"
    end

    test "dangling timeout transition_to fails" do
      dsl =
        build_dsl([
          step(:waiting,
            manual: true,
            transitions: [transition(:go, :done)],
            timeouts: [timeout(:esc, transition_to: :nonexistent)]
          ),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "references unknown step :nonexistent"
    end
  end

  describe "transition name uniqueness" do
    test "duplicate transition names across steps fails" do
      dsl =
        build_dsl([
          step(:step_a, manual: true, transitions: [transition(:approve, :done)]),
          step(:step_b,
            manual: true,
            transitions: [transition(:approve, :done), transition(:back, :step_a)]
          ),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "Transition name :approve is used in multiple steps"
    end

    test "same transition name within one step is allowed" do
      # Two different transitions in the same step don't conflict — they're different actions
      dsl =
        build_dsl([
          step(:review,
            manual: true,
            transitions: [transition(:approve, :done), transition(:reject, :rejected)]
          ),
          step(:done, terminal: true),
          step(:rejected, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end
  end

  describe "reachability" do
    test "unreachable step fails" do
      dsl =
        build_dsl([
          step(:start, manual: true, transitions: [transition(:go, :done)]),
          step(:orphan, manual: true, transitions: [transition(:go_too, :done)]),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "not reachable from the first step"
      assert message =~ ":orphan"
    end

    test "all terminal steps fails" do
      dsl = build_dsl([step(:done, terminal: true)])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "at least one non-terminal step"
    end

    test "empty workflow fails" do
      dsl = build_dsl([])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "at least one non-terminal step"
    end
  end
end
