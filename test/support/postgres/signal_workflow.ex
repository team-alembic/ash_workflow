defmodule AshWorkflowTest.Postgres.SignalWorkflow do
  @moduledoc """
  Postgres-backed workflow whose `approve` emits `:approved`, so a test can
  show `AshWorkflowTest.SignalListener` failing rolls the transition back
  inside a real transaction.

      review ──(approve)──▶ approved
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "signal_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    signals AshWorkflowTest.Signals

    step :review do
      transition :approve do
        to :approved
        emit :approved, values: [verdict: "approved"]
      end
    end

    step :approved, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end
end
