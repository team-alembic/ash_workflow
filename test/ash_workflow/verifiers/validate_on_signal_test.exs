# The workflows these tests compile stay loaded and are in no domain, so they
# listen on signals no other test emits.
defmodule AshWorkflow.Verifiers.ValidateOnSignalTest.Signals do
  @moduledoc false
  use Ash.Signals

  signals do
    signal :payment_settled do
      argument :order_id, :uuid, allow_nil?: false
    end

    signal :address_changed do
      argument :order_id, :uuid, allow_nil?: false
      argument :address, :string
    end

    signal :order_withdrawn do
      argument :reference, :string, allow_nil?: false
    end
  end
end

defmodule AshWorkflow.Verifiers.ValidateOnSignalTest do
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  defp workflow(name, handler, opts \\ []) do
    signals =
      Keyword.get(opts, :signals, "signals AshWorkflow.Verifiers.ValidateOnSignalTest.Signals")

    """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshWorkflowTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshWorkflow]

      workflow do
        scheduler AshWorkflow.Scheduler.Precise
        #{signals}

        step :awaiting_payment do
          transition :mark_paid, to: :fulfilling

    #{handler}
        end

    #{Keyword.get(opts, :terminal_step, "    step :fulfilling, terminal: true")}
      end

      actions do
        defaults [:read, create: []]

        read :by_reference do
          argument :reference, :string
        end

        read :by_note do
          argument :note, :string
        end

        update :touch do
          accept []
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :reference, :string, public?: true
      end
    end
    """
  end

  test "accepts a valid handler" do
    assert_dsl_compiles(
      workflow("ValidOnSignalWorkflow", """
            on_signal :payment_settled do
              filter expr(id == ^signal(:order_id))
              transition_to :fulfilling
            end
      """)
    )
  end

  test "rejects a handler with no signals module" do
    assert_dsl_error(
      workflow(
        "NoModuleOnSignalWorkflow",
        """
              on_signal :payment_settled do
                filter expr(id == ^signal(:order_id))
                transition_to :fulfilling
              end
        """,
        signals: ""
      ),
      ~r/on_signal :payment_settled needs a signals module/
    )
  end

  test "rejects a from that is not an Ash.Signals module" do
    assert_dsl_error(
      workflow("NotSignalsOnSignalWorkflow", """
            on_signal :payment_settled do
              from AshWorkflowTest.Domain
              filter expr(id == ^signal(:order_id))
              transition_to :fulfilling
            end
      """),
      ~r/`AshWorkflowTest.Domain` is not an `Ash.Signals` module/
    )
  end

  test "rejects a signal the module does not declare" do
    assert_dsl_error(
      workflow("UnknownOnSignalWorkflow", """
            on_signal :no_such_signal do
              filter expr(id == ^signal(:order_id))
              transition_to :fulfilling
            end
      """),
      ~r/has no signal named :no_such_signal/
    )
  end

  test "rejects a filter naming a field the signal does not declare" do
    assert_dsl_error(
      workflow("UnknownFieldOnSignalWorkflow", """
            on_signal :payment_settled do
              filter expr(reference == ^signal(:reference))
              transition_to :fulfilling
            end
      """),
      ~r/`filter` uses `signal\(:reference\)`, but signal :payment_settled has no field/
    )
  end

  test "rejects neither filter nor read_action" do
    assert_dsl_error(
      workflow("NoSelectorOnSignalWorkflow", """
            on_signal :payment_settled do
              transition_to :fulfilling
            end
      """),
      ~r/must declare either `filter` or `read_action`/
    )
  end

  test "rejects both filter and read_action" do
    assert_dsl_error(
      workflow("BothSelectorsOnSignalWorkflow", """
            on_signal :order_withdrawn do
              filter expr(reference == ^signal(:reference))
              read_action :by_reference
              transition_to :fulfilling
            end
      """),
      ~r/declares both `filter` and `read_action`/
    )
  end

  test "rejects a read_action that is not a read action" do
    assert_dsl_error(
      workflow("BadReadOnSignalWorkflow", """
            on_signal :order_withdrawn do
              read_action :touch
              transition_to :fulfilling
            end
      """),
      ~r/`read_action` :touch is not a read action/
    )
  end

  test "rejects a read_action argument the signal cannot set" do
    assert_dsl_error(
      workflow("BadArgOnSignalWorkflow", """
            on_signal :order_withdrawn do
              read_action :by_note
              transition_to :fulfilling
            end
      """),
      ~r/takes argument :note, but signal :order_withdrawn has no field/
    )
  end

  test "rejects neither transition_to nor action" do
    assert_dsl_error(
      workflow("NoOutcomeOnSignalWorkflow", """
            on_signal :payment_settled do
              filter expr(id == ^signal(:order_id))
            end
      """),
      ~r/must declare either `transition_to` or `action`/
    )
  end

  test "rejects both transition_to and action" do
    assert_dsl_error(
      workflow("BothOutcomesOnSignalWorkflow", """
            on_signal :payment_settled do
              filter expr(id == ^signal(:order_id))
              transition_to :fulfilling
              action :touch
            end
      """),
      ~r/declares both `transition_to` and `action`/
    )
  end

  test "rejects a transition_to that is not a step" do
    assert_dsl_error(
      workflow("UnknownTargetOnSignalWorkflow", """
            on_signal :payment_settled do
              filter expr(id == ^signal(:order_id))
              transition_to :nowhere
            end
      """),
      ~r/transitions to :nowhere, which is not a step/
    )
  end

  test "rejects an action that is not an update action" do
    assert_dsl_error(
      workflow("BadActionOnSignalWorkflow", """
            on_signal :payment_settled do
              filter expr(id == ^signal(:order_id))
              action :by_reference
            end
      """),
      ~r/runs :by_reference, which is not an update action/
    )
  end

  test "rejects a handler on a terminal step" do
    assert_dsl_error(
      workflow("TerminalOnSignalWorkflow", "",
        terminal_step: """
            step :fulfilling do
              terminal true

              on_signal :payment_settled do
                filter expr(id == ^signal(:order_id))
                transition_to :awaiting_payment
              end
            end
        """
      ),
      ~r/on_signal :payment_settled is declared on terminal step :fulfilling/
    )
  end

  test "rejects an action that a timeout also runs" do
    assert_dsl_error(
      workflow("SharedTimeoutActionOnSignalWorkflow", """
            on_signal :address_changed do
              filter expr(id == ^signal(:order_id))
              action :touch
            end

            timeout :remind do
              fire_after {1, :days}
              action :touch
            end
      """),
      ~r/on_signal :address_changed runs :touch, which timeout :remind on step :awaiting_payment also runs/
    )
  end

  test "accepts two handlers that run the same action" do
    assert_dsl_compiles(
      workflow("SharedHandlerActionOnSignalWorkflow", """
            on_signal :address_changed do
              filter expr(id == ^signal(:order_id))
              action :touch
            end

            on_signal :order_withdrawn do
              filter expr(reference == ^signal(:reference))
              action :touch
            end
      """)
    )
  end
end
