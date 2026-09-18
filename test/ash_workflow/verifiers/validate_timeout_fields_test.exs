defmodule AshWorkflow.Verifiers.ValidateTimeoutFieldsTest do
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  describe "timeout field validation" do
    test "rejects a timeout whose field does not exist" do
      assert_dsl_error(
        """
        defmodule BadFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              timeout :bad_timeout,
                fire_after: {3, :days},
                field: :nonexistent_field,
                transition_to: :escalated
            end

            step :done, terminal: true
            step :escalated, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end
        end
        """,
        ~r/references field :nonexistent_field/
      )
    end

    test "rejects a timeout field that is not a datetime type" do
      assert_dsl_error(
        """
        defmodule NonDatetimeFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              timeout :bad_type,
                fire_after: {3, :days},
                field: :priority,
                transition_to: :escalated
            end

            step :done, terminal: true
            step :escalated, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
            attribute :priority, :integer, public?: true
          end
        end
        """,
        ~r/must be a datetime type/
      )
    end

    test "rejects a timeout field referencing a module calculation" do
      assert_dsl_error(
        """
        defmodule ModuleCalcFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              timeout :bad_calc,
                fire_after: {3, :days},
                field: :entered_current_state_at,
                transition_to: :escalated
            end

            step :done, terminal: true
            step :escalated, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end

          calculations do
            calculate :entered_current_state_at,
                      :utc_datetime_usec,
                      AshWorkflow.Calculations.EnteredCurrentStateAt
          end
        end
        """,
        ~r/cannot be evaluated by the data layer/
      )
    end

    test "accepts a timeout field referencing an expression calculation" do
      assert AshWorkflowTest.ExprCalcTimeoutWorkflow.__info__(:module) ==
               AshWorkflowTest.ExprCalcTimeoutWorkflow
    end

    test "accepts field referencing an existing attribute" do
      assert AshWorkflowTest.FieldTimeoutWorkflow.__info__(:module) ==
               AshWorkflowTest.FieldTimeoutWorkflow
    end

    test "accepts default state_entered_at field" do
      assert AshWorkflowTest.TimeoutWorkflow.__info__(:module) ==
               AshWorkflowTest.TimeoutWorkflow
    end
  end
end
