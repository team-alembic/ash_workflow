defmodule AshWorkflow.InitialStepTest do
  use ExUnit.Case, async: true

  import AshWorkflowTest.DslAssertions

  alias AshStateMachine.Info, as: SMInfo

  describe "initial: true flag" do
    test "step with initial: true becomes the initial state, overriding declaration order" do
      # :draft is declared first but :review has initial: true
      assert {:ok, :review} =
               SMInfo.state_machine_default_initial_state(AshWorkflowTest.InitialFlagWorkflow)
    end

    test "workflow starts in the initial step" do
      {:ok, record} = AshWorkflowTest.InitialFlagWorkflow.create(%{title: "test"})
      assert record.state == :review
    end
  end

  describe "verifier" do
    test "rejects a workflow where multiple steps have initial: true" do
      assert_dsl_error(
        """
        defmodule MultipleInitialWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :step_a do
              initial true
              transition :go, to: :step_b
            end

            step :step_b do
              initial true
              transition :finish, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
        """,
        ~r/Only one step can have initial: true/
      )
    end

    test "rejects a terminal step marked initial: true" do
      assert_dsl_error(
        """
        defmodule TerminalInitialWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :review do
              transition :approve, to: :done
            end

            step :done, terminal: true, initial: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
        """,
        ~r/Terminal step .* cannot have initial: true/
      )
    end
  end
end
