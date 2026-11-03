defmodule AshWorkflow.Verifiers.ValidateTimeoutFiredFieldsTest do
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  alias Ash.Resource.Info, as: ResourceInfo

  test "accepts an existing datetime attribute under the fired column's name" do
    {:module, module, _binary, _term} =
      defmodule OwnFiredColumnWorkflow do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow, AshOban]

        workflow do
          step :waiting do
            transition :resolve, to: :done
            timeout :reminder, fire_after: {1, :days}, action: :send_reminder
          end

          step :done, terminal: true
        end

        actions do
          defaults [:read]

          update :send_reminder do
            accept []
          end
        end

        attributes do
          uuid_v7_primary_key :id
          attribute :waiting_reminder_fired_at, :utc_datetime, public?: true
        end
      end

    assert ResourceInfo.attribute(module, :waiting_reminder_fired_at).type ==
             Ash.Type.UtcDatetime
  end

  test "rejects an existing attribute of a non-datetime type under the fired column's name" do
    assert_dsl_error(
      """
      defmodule StringFiredColumnWorkflow do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow, AshOban]

        workflow do
          step :waiting do
            transition :resolve, to: :done
            timeout :reminder, fire_after: {1, :days}, action: :send_reminder
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
          attribute :waiting_reminder_fired_at, :string, public?: true
        end
      end
      """,
      ~r/timeout :reminder on step :waiting records its firing in :waiting_reminder_fired_at, which is an existing attribute of type Ash.Type.String/
    )
  end

  # Under `AshWorkflow.Scheduler.Oban` the same names also collide as trigger
  # names, which AshOban rejects first. Precise has no triggers, so only this
  # verifier catches it.
  test "rejects two action timeouts whose names generate the same fired column" do
    assert_dsl_error(
      """
      defmodule CollidingFiredColumnWorkflow do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow]

        workflow do
          scheduler AshWorkflow.Scheduler.Precise

          step :a_b do
            transition :next, to: :a
            timeout :c, fire_after: {1, :days}, action: :nudge
          end

          step :a do
            transition :finish, to: :done
            timeout :b_c, fire_after: {1, :days}, action: :nudge
          end

          step :done, terminal: true
        end

        actions do
          update :nudge do
            accept []
          end
        end

        attributes do
          uuid_v7_primary_key :id
        end
      end
      """,
      ~r/timeout :c on step :a_b, timeout :b_c on step :a all record their firing in :a_b_c_fired_at/
    )
  end

  test "rejects an every whose last_fired_field is an action timeout's fired column" do
    assert_dsl_error(
      """
      defmodule EveryOnFiredColumnWorkflow do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow, AshOban]

        workflow do
          step :waiting do
            transition :resolve, to: :done
            timeout :reminder, fire_after: {1, :days}, action: :send_reminder

            every :follow_up do
              interval {2, :days}
              action :send_reminder
              last_fired_field :waiting_reminder_fired_at
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
        end
      end
      """,
      ~r/timeout :reminder on step :waiting, every :follow_up on step :waiting all record their firing in :waiting_reminder_fired_at/
    )
  end

  test "a transition timeout gets no fired column" do
    refute ResourceInfo.attribute(
             AshWorkflowTest.TimeoutWorkflow,
             :waiting_escalation_fired_at
           )

    assert ResourceInfo.attribute(
             AshWorkflowTest.TimeoutWorkflow,
             :waiting_reminder_fired_at
           )
  end
end
