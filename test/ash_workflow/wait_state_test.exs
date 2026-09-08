defmodule AshWorkflow.WaitStateTest do
  @moduledoc """
  A wait state is a step with no action and no transitions: nothing runs when a
  record arrives, and no caller can move it along. A timeout is its only exit.
  """
  use ExUnit.Case, async: true

  import AshWorkflowTest.DslAssertions

  alias AshOban.Info, as: ObanInfo
  alias AshStateMachine.Info, as: SMInfo
  alias AshWorkflow.Entities.Step
  alias AshWorkflowTest.WaitStateWorkflow

  describe "Step.wait_state?/1" do
    test "a step whose only exit is a timeout is a wait state" do
      step = %Step{name: :queued, timeouts: [%{transition_to: :running}]}

      assert Step.wait_state?(step)
      assert Step.manual?(step)
    end

    test "a step with an action is not a wait state" do
      step = %Step{name: :verifying, action: :verify, timeouts: [%{transition_to: :late}]}

      refute Step.wait_state?(step)
      refute Step.manual?(step)
    end

    test "a step with transitions is not a wait state" do
      step = %Step{name: :review, transitions: [%{name: :approve}]}

      refute Step.wait_state?(step)
      assert Step.manual?(step)
    end

    test "a terminal step is never a wait state" do
      step = %Step{name: :done, terminal: true, timeouts: [%{transition_to: :other}]}

      refute Step.wait_state?(step)
    end
  end

  describe "a compiled wait state" do
    test "is the initial step when declared first" do
      assert {:ok, :queued} = SMInfo.state_machine_default_initial_state(WaitStateWorkflow)
    end

    test "records start in it" do
      {:ok, record} = WaitStateWorkflow.create(%{title: "job"})

      assert record.state == :queued
    end

    test "generates no action of its own, because nothing runs on entry" do
      refute Enum.any?(Ash.Resource.Info.actions(WaitStateWorkflow), &(&1.name == :queued))
    end

    test "generates its timeout trigger, which is how records leave" do
      names = Enum.map(ObanInfo.oban_triggers(WaitStateWorkflow), & &1.name)

      assert :__timeout_trigger_queued_release in names
    end

    test "does not generate an automatic-step trigger" do
      names = Enum.map(ObanInfo.oban_triggers(WaitStateWorkflow), & &1.name)

      refute :queued in names
    end

    test "the timeout's transition is a valid state change" do
      transitions = SMInfo.state_machine_transitions(WaitStateWorkflow)

      assert Enum.any?(transitions, &(&1.from == [:queued] and &1.to == [:running]))
    end
  end

  describe "verifier" do
    test "rejects a wait state whose timeouts cannot move it anywhere" do
      assert_dsl_error(
        """
        defmodule DeadEndWaitWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :queued do
              timeout :nudge, after: {1, :days}, action: :remind
            end

            step :done, terminal: true
          end

          actions do
            update :remind do
              accept []
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
        """,
        ~r/none of its timeouts declare transition_to/
      )
    end

    test "rejects a wait state that declares on_success" do
      assert_dsl_error(
        """
        defmodule WaitOnSuccessWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :queued do
              on_success :running
              timeout :release, after: {1, :days}, transition_to: :running
            end

            step :running, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
        """,
        ~r/on_success would never fire/
      )
    end

    test "still rejects a step with no action, no transitions and no timeouts" do
      assert_dsl_error(
        """
        defmodule StrandedStepWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :stranded

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
        """,
        ~r/must either declare an action .*, at least one transition .*, or a timeout with transition_to/
      )
    end
  end
end
