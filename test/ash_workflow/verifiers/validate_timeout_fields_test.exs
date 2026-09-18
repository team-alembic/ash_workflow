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

    test "rejects repeat: true combined with a custom field" do
      assert_dsl_error(
        """
        defmodule RepeatWithFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :active do
              transition :deactivate, to: :inactive

              timeout :bad_repeat,
                fire_after: {3, :days},
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

    test "accepts repeat: true with default state_entered_at field" do
      assert AshWorkflowTest.RepeatingTimeoutWorkflow.__info__(:module) ==
               AshWorkflowTest.RepeatingTimeoutWorkflow
    end

    test "accepts repeat_until with no explicit repeat: true, and treats it as repeating" do
      assert AshWorkflowTest.RepeatUntilWorkflow.__info__(:module) ==
               AshWorkflowTest.RepeatUntilWorkflow

      timeout =
        AshWorkflowTest.RepeatUntilWorkflow
        |> AshWorkflow.Info.workflow_graph()
        |> Map.fetch!(:waiting)
        |> Map.fetch!(:timeouts)
        |> Enum.find(&(&1.name == :reminder))

      assert timeout.repeat == true
      assert timeout.repeat_until == {3, :hours}
    end

    test "rejects repeat_until shorter than fire_after" do
      assert_dsl_error(
        """
        defmodule TooShortRepeatUntilWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              timeout :reminder do
                fire_after {3, :days}
                action :send_reminder
                repeat_until {1, :days}
              end
            end

            step :done, terminal: true
          end

          actions do
            update :send_reminder do
              accept []
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end
        end
        """,
        ~r/repeat_until: \{1, :days\}, which is shorter than fire_after/
      )
    end

    test "rejects repeat_until combined with a custom field, since it implies repeat: true" do
      assert_dsl_error(
        """
        defmodule RepeatUntilWithFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :active do
              transition :deactivate, to: :inactive

              timeout :bad_repeat_until do
                fire_after {3, :days}
                field :last_session_date
                action :send_reminder
                repeat_until {9, :days}
              end
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
