defmodule AshWorkflow.InitialStepTest do
  use ExUnit.Case, async: true

  alias AshStateMachine.Info, as: SMInfo

  describe "initial: true flag" do
    test "step with initial: true becomes the initial state, overriding declaration order" do
      # :draft is declared first but :review has initial: true
      assert {:ok, :review} =
               SMInfo.state_machine_default_initial_state(AshWorkflowTest.InitialFlagWorkflow)
    end

    test "workflow starts in the initial step" do
      {:ok, record} = AshWorkflowTest.InitialFlagWorkflow.start(%{title: "test"})
      assert record.state == :review
    end
  end

  describe "verifier" do
    test "raises when multiple steps have initial: true" do
      assert_raise Spark.Error.DslError, ~r/Only one step can have initial: true/, fn ->
        defmodule MultipleInitialWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :step_a do
              initial true
              manual true
              transition :go, to: :step_b
            end

            step :step_b do
              initial true
              manual true
              transition :finish, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
      end
    end

    test "raises when terminal step has initial: true" do
      assert_raise Spark.Error.DslError, ~r/Terminal step .* cannot have initial: true/, fn ->
        defmodule TerminalInitialWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :review do
              manual true
              transition :approve, to: :done
            end

            step :done, terminal: true, initial: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
      end
    end
  end
end
