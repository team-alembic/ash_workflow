defmodule AshWorkflowTest.WaitStateWorkflow do
  @moduledoc """
  Workflow with a wait state: `:queued` runs nothing on entry and offers no
  caller-facing transition, so its timeout is the only way out.

  queued ──(1s after release_at)──→ running ──(finish)──→ done
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :queued do
      timeout :release,
        after: {1, :minutes},
        field: :release_at,
        transition_to: :running
    end

    step :running do
      transition :finish, to: :done
    end

    step :done, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :release_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :release_at, :utc_datetime_usec, public?: true
  end
end
