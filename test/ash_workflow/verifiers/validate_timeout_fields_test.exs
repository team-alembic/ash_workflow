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
            extensions: [AshWorkflow]

          workflow do
            step :waiting do
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
        """,
        ~r/references field :nonexistent_field/
      )
    end

    test "rejects repeat: true combined with a custom field" do
      assert_dsl_error(
        """
        defmodule RepeatWithFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :active do
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
        """,
        ~r/repeat: true with field:/
      )
    end

    test "rejects a timeout field that is not a datetime type" do
      assert_dsl_error(
        """
        defmodule NonDatetimeFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :waiting do
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
        """,
        ~r/must be a datetime type/
      )
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
