defmodule AshWorkflow.Verifiers.ValidateWorkflowTest do
  @moduledoc """
  Tests the workflow verifier by calling it directly with mock DSL state.

  We build a minimal map that satisfies `Verifier.get_entities(dsl, [:workflow])`
  and call `ValidateWorkflow.verify/1` directly.
  """
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  alias AshWorkflow.Entities.{Step, Timeout, Transition}
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
          step(:review, transitions: [transition(:approve, :done)]),
          step(:done, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end

    test "step with timeouts" do
      dsl =
        build_dsl([
          step(:waiting,
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

    test "step with neither action nor transitions fails" do
      dsl =
        build_dsl([
          step(:broken, on_success: :done),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must either declare an action"
      assert message =~ "at least one transition"
    end

    test "step with both action and transitions fails" do
      dsl =
        build_dsl([
          step(:review, action: :something, transitions: [transition(:go, :done)]),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "cannot also define an action"
    end

    test "step with transitions and on_success fails" do
      dsl =
        build_dsl([
          step(:review, on_success: :done, transitions: [transition(:go, :done)]),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "cannot also define on_success"
    end

    test "step with transitions and on_error fails" do
      dsl =
        build_dsl([
          step(:review, on_error: :done, transitions: [transition(:go, :done)]),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "cannot also define on_error"
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
          step(:start, transitions: [transition(:go, :done)]),
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
          step(:waiting, transitions: [transition(:go, :nowhere)])
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "references unknown step :nowhere"
    end

    test "dangling timeout transition_to fails" do
      dsl =
        build_dsl([
          step(:waiting,
            transitions: [transition(:go, :done)],
            timeouts: [timeout(:esc, transition_to: :nonexistent)]
          ),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "references unknown step :nonexistent"
    end
  end

  describe "shared transition names" do
    test "same transition name across steps with same target is allowed" do
      dsl =
        build_dsl([
          step(:step_a,
            transitions: [transition(:reject, :rejected), transition(:go_to_b, :step_b)]
          ),
          step(:step_b,
            transitions: [transition(:reject, :rejected), transition(:back, :step_a)]
          ),
          step(:rejected, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end

    test "same transition name across steps with different targets is allowed" do
      dsl =
        build_dsl([
          step(:step_a,
            transitions: [transition(:complete, :done_a), transition(:go_to_b, :step_b)]
          ),
          step(:step_b,
            transitions: [transition(:complete, :done_b), transition(:back, :step_a)]
          ),
          step(:done_a, terminal: true),
          step(:done_b, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end

    test "different transitions within one step is fine" do
      dsl =
        build_dsl([
          step(:review,
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
          step(:start, transitions: [transition(:go, :done)]),
          step(:orphan, transitions: [transition(:go_too, :done)]),
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

  describe "compiling a resource with no steps" do
    # The tests above call the verifier directly. These compile a real resource,
    # because the transformers run first: a step-less workflow used to raise
    # `expected a map, got: nil` from AddStateMachine before the verifier could
    # report anything useful. That is the state of every resource between
    # `mix ash.extend` and writing its first step.
    test "the extension with no workflow block at all reports the missing steps" do
      assert_dsl_error(
        """
        defmodule NoWorkflowBlockResource do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/at least one non-terminal step/
      )
    end

    test "an empty workflow block reports the missing steps" do
      assert_dsl_error(
        """
        defmodule EmptyWorkflowBlockResource do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/at least one non-terminal step/
      )
    end
  end

  describe "shared transition names with differing policies" do
    test "rejects two steps sharing a transition name with different policies" do
      AshWorkflowTest.DslAssertions.assert_dsl_error(
        """
        defmodule ConflictingPolicyWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshWorkflow]

          workflow do
            step :queue do
              policy actor_attribute_equals(:role, :agent)

              transition :resolve, to: :resolved
              transition :escalate, to: :escalated
            end

            step :escalated do
              policy actor_attribute_equals(:role, :manager)

              transition :resolve, to: :resolved
            end

            step :resolved, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/Transition :resolve is declared on steps with different policies/
      )
    end

    test "allows a shared transition name when the policies match" do
      # Same check on both steps means one policy on the merged action, which
      # behaves as written.
      assert AshWorkflowTest.SharedTransitionWorkflow.__info__(:module)
    end
  end
end
