defmodule AshWorkflowTest.UpsertWorkflow do
  @moduledoc """
  A logged workflow whose create action upserts on an identity, so a second
  create for the same code returns the existing row.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  ets do
    private? true
  end

  workflow do
    scheduler AshWorkflowTest.NotifyingScheduler
    transition_log AshWorkflowTest.UpsertLog

    step :open do
      transition :close, to: :closed
    end

    step :closed, terminal: true
  end

  actions do
    defaults [:read]

    create :open do
      accept [:code]
      upsert? true
      upsert_identity :unique_code
      upsert_fields []
    end

    # The identity's `pre_check_with` adds a `before_action` hook, which an
    # atomic update cannot run.
    update :close do
      require_atomic? false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_code, [:code], pre_check_with: AshWorkflowTest.Domain
  end
end
