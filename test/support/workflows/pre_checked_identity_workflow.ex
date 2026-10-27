defmodule AshWorkflowTest.PreCheckedIdentityWorkflow do
  @moduledoc """
  A workflow on a data layer without unique constraints, whose identity is
  checked with `pre_check_with`.

      open ──(close)──▶ closed
      open ──(deadline_at passes)──▶ lapsed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  ets do
    private? true
  end

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :open do
      transition :close, to: :closed

      timeout :lapse do
        fire_at :deadline_at
        transition_to :lapsed
      end
    end

    step :closed, terminal: true
    step :lapsed, terminal: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:code, :deadline_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :deadline_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_code, [:code], pre_check_with: AshWorkflowTest.Domain
  end
end
