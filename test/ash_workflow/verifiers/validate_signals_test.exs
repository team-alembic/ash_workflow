defmodule AshWorkflow.Verifiers.ValidateSignalsTest do
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  defp workflow(name, workflow_body) do
    """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshWorkflowTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshWorkflow]

      workflow do
        scheduler AshWorkflow.Scheduler.Precise
    #{workflow_body}
        step :review do
          transition :approve, to: :done
        end

        step :done, terminal: true
      end

      actions do
        defaults [:read, create: [:name]]
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :name, :string, public?: true
      end
    end
    """
  end

  test "accepts a workflow whose emits all fill their signals" do
    assert_dsl_compiles(
      workflow("ValidSignalsWorkflow", """
          signals AshWorkflowTest.Signals
          emit :state_changed
          emit :approved, fields: [:name], values: [verdict: "approved"]
      """)
    )
  end

  test "rejects an emit without a signals module" do
    assert_dsl_error(
      workflow("NoSignalsModuleWorkflow", "    emit :state_changed\n"),
      ~r/emit :state_changed needs the workflow to name its signals module/
    )
  end

  test "rejects a signals module that is not an Ash.Signals module" do
    assert_dsl_error(
      workflow("NotSignalsModuleWorkflow", """
          signals AshWorkflowTest.Domain
          emit :state_changed
      """),
      ~r/`signals AshWorkflowTest.Domain` is not an `Ash.Signals` module/
    )
  end

  test "rejects an emit naming a signal the module does not declare" do
    assert_dsl_error(
      workflow("UnknownSignalWorkflow", """
          signals AshWorkflowTest.Signals
          emit :no_such_signal
      """),
      ~r/has no signal named :no_such_signal/
    )
  end

  test "rejects a signal that is not emitted during after_action" do
    assert_dsl_error(
      workflow("BeforeActionSignalWorkflow", """
          signals AshWorkflowTest.Signals
          emit :before_change
      """),
      ~r/workflows only emit :after_action signals for now/
    )
  end

  test "rejects fields setting a signal field the signal does not declare" do
    assert_dsl_error(
      workflow("UnknownFieldWorkflow", """
          signals AshWorkflowTest.Signals
          emit :reminded, fields: [:name]
      """),
      ~r/`fields` sets :name, but signal :reminded has no field with that name/
    )
  end

  test "rejects fields mapping to something that is not an attribute" do
    assert_dsl_error(
      workflow("NotAttributeFieldWorkflow", """
          signals AshWorkflowTest.Signals
          emit :review_started, fields: [name: :nickname]
      """),
      ~r/maps :name to :nickname, which is not an attribute of the resource/
    )
  end

  test "rejects values setting a signal field the signal does not declare" do
    assert_dsl_error(
      workflow("UnknownValueWorkflow", """
          signals AshWorkflowTest.Signals
          emit :reminded, values: [reason: "late"]
      """),
      ~r/`values` sets :reason, but signal :reminded has no field with that name/
    )
  end

  test "rejects a required signal field nothing fills" do
    assert_dsl_error(
      workflow("UnfilledFieldWorkflow", """
          signals AshWorkflowTest.Signals
          emit :needs_priority
      """),
      ~r/requires :priority, which emit :needs_priority does not fill/
    )
  end

  test "rejects a state field that is not an atom" do
    assert_dsl_error(
      workflow("StringStateWorkflow", """
          signals AshWorkflowTest.Signals
          emit :string_state
      """),
      ~r/declares :to_state as Ash.Type.String, but the workflow fills it with a step name/
    )
  end

  test "checks emits nested in a transition" do
    assert_dsl_error(
      """
      defmodule NestedUnknownSignalWorkflow do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow]

        workflow do
          scheduler AshWorkflow.Scheduler.Precise
          signals AshWorkflowTest.Signals

          step :review do
            transition :approve do
              to :done
              emit :no_such_signal
            end
          end

          step :done, terminal: true
        end

        actions do
          defaults [:read, create: [:name]]
        end

        attributes do
          uuid_v7_primary_key :id
          attribute :name, :string, public?: true
        end
      end
      """,
      ~r/has no signal named :no_such_signal/
    )
  end
end
