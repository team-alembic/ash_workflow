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

    test "raises when repeat: true is used with a custom field" do
      assert_raise Spark.Error.DslError, ~r/repeat: true with field:/, fn ->
        defmodule RepeatWithFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :active do
              manual true
              transition :deactivate, to: :inactive

              timeout :bad_repeat,
                after: {3, :days},
                field: :last_session_date,
                action: :send_reminder,
                repeat: true
            end

            step :inactive, terminal: true
          end

          actions do
            update :send_reminder do
              accept []
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
            attribute :last_session_date, :utc_datetime_usec, public?: true
          end
        end
      end
    end

    test "raises when field is not a datetime type" do
      assert_raise Spark.Error.DslError, ~r/must be a datetime type/, fn ->
        defmodule NonDatetimeFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :waiting do
              manual true
              transition :resolve, to: :done

              timeout :bad_type,
                after: {3, :days},
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
      end
    end

    test "accepts repeat: true with default state_entered_at field" do
      assert AshWorkflowTest.RepeatingTimeoutWorkflow.__info__(:module) ==
               AshWorkflowTest.RepeatingTimeoutWorkflow
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
