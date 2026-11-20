defmodule AshWorkflowTest.MultipleInitialRuntimeWorkflow do
  @moduledoc """
  Workflow with three initial steps, used to show a create can start in any of
  them: a manual step, an automatic step and a wait state. `:intake` is also
  reached from `:review` by `reopen`.

  start → drafting ──(submit)──→ intake
  start → intake ──(process_intake)──→ review ──(approve)──→ done
                                              └─(reopen)───→ intake
  start → parked ── after 3 days ──→ drafting
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    signals AshWorkflowTest.MultipleInitialSignals

    transition_log AshWorkflowTest.MultipleInitialRuntimeLog

    step :drafting do
      initial true
      emit :drafting_started
      transition :submit, to: :intake
    end

    step :intake do
      initial true
      emit :intake_started
      action :process_intake
      on_success :review
    end

    step :parked do
      initial true
      timeout :release, fire_after: {3, :days}, transition_to: :drafting
    end

    step :review do
      transition :approve, to: :done
      transition :reopen, to: :intake
    end

    step :done, terminal: true
  end

  code_interface do
    define :create
    define :create_at_intake
    define :create_at_parked
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title]
    end

    create :create_at_intake do
      accept [:title]
      change transition_state(:intake)
    end

    create :create_at_parked do
      accept [:title]
      change transition_state(:parked)
    end

    update :process_intake do
      accept []
    end

    update :touch do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
