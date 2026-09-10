defmodule AshWorkflow.Verifiers.ValidateStepPoliciesTest do
  @moduledoc """
  A policy with no authorizer to enforce it is a compile error.
  """
  use ExUnit.Case, async: true

  import AshWorkflowTest.DslAssertions

  describe "a step policy without an authorizer" do
    test "is rejected" do
      assert_dsl_error(
        """
        defmodule UnenforcedStepPolicyWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :review do
              policy actor_attribute_equals(:role, :reviewer)
              transition :approve, to: :approved
            end

            step :approved, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/step :review declares a policy, but this resource has no authorizer/
      )
    end

    test "names every step that declares one" do
      assert_dsl_error(
        """
        defmodule TwoUnenforcedPoliciesWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :review do
              policy actor_attribute_equals(:role, :reviewer)
              transition :approve, to: :sign_off
            end

            step :sign_off do
              policy actor_attribute_equals(:role, :admin)
              transition :complete, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/step :review, step :sign_off declares a policy/
      )
    end

    test "is accepted with Ash.Policy.Authorizer" do
      assert_dsl_compiles("""
      defmodule EnforcedStepPolicyWorkflow do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshWorkflow, AshOban]

        workflow do
          step :review do
            policy actor_attribute_equals(:role, :reviewer)
            transition :approve, to: :approved
          end

          step :approved, terminal: true
        end

        attributes do
          uuid_v7_primary_key :id
        end
      end
      """)
    end

    test "a workflow with no policy at all is accepted" do
      assert_dsl_compiles("""
      defmodule NoPolicyWorkflow do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow, AshOban]

        workflow do
          step :review do
            transition :approve, to: :approved
          end

          step :approved, terminal: true
        end

        attributes do
          uuid_v7_primary_key :id
        end
      end
      """)
    end
  end
end
