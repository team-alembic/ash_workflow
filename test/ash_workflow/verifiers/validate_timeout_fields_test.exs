defmodule AshWorkflow.Verifiers.ValidateTimeoutFieldsTest do
  use ExUnit.Case

  describe "timeout field validation" do
    test "raises when field references a nonexistent attribute" do
      assert_raise Spark.Error.DslError, ~r/references field :nonexistent_field/, fn ->
        defmodule BadFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :waiting do
              manual true
              transition :resolve, to: :done

              timeout :bad_timeout,
                after: {3, :days},
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
      end
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
