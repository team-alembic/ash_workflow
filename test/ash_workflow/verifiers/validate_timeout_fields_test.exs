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
        ~r/repeats with field:/
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

    test "accepts a repeat block with a bound, and reports it as repeating" do
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

    test "accepts a repeat bound anchored on an attribute of the record" do
      assert AshWorkflowTest.RepeatAnchorWorkflow.__info__(:module) ==
               AshWorkflowTest.RepeatAnchorWorkflow
    end

    test "rejects a repeat bound anchored on state_entered_at, which the repeat resets" do
      assert_dsl_error(
        """
        defmodule SelfDefeatingAnchorWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              timeout :reminder do
                fire_after {1, :days}
                action :send_reminder
                repeat true do
                  until {8, :days}
                  field :state_entered_at
                end
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
        ~r/anchors its repeat bound on :state_entered_at, which the repeat resets/
      )
    end

    test "rejects a repeat bound anchored on a field that does not exist" do
      assert_dsl_error(
        """
        defmodule MissingAnchorWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              timeout :reminder do
                fire_after {1, :days}
                action :send_reminder
                repeat true do
                  until {8, :days}
                  field :nonexistent_anchor
                end
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
        ~r/anchors its repeat bound on :nonexistent_anchor, but no attribute or calculation/
      )
    end

    test "rejects a bound declared on a repeat that is switched off" do
      assert_dsl_error(
        """
        defmodule DisabledRepeatBoundWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              timeout :reminder do
                fire_after {1, :days}
                action :send_reminder
                repeat false do
                  until {8, :days}
                end
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
        ~r/declares `repeat false` with `until \{8, :days\}`/
      )
    end

    test "rejects a repeat bound shorter than fire_after" do
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
                repeat true do
                  until {1, :days}
                end
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
        ~r/until: \{1, :days\} in its repeat, which is not longer than fire_after/
      )
    end

    test "rejects a repeat bound equal to fire_after, since that leaves no room to fire even once" do
      assert_dsl_error(
        """
        defmodule EqualRepeatUntilWorkflow do
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
                repeat true do
                  until {3, :days}
                end
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
        ~r/until: \{3, :days\} in its repeat, which is not longer than fire_after/
      )
    end

    test "rejects a bounded repeat combined with a custom field" do
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
                repeat true do
                  until {9, :days}
                end
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
        ~r/repeats with field:/
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
