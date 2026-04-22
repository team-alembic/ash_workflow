defmodule AshWorkflowTest.SharedTransitionWorkflow do
  @moduledoc """
  Workflow where :reject is used in multiple steps with the same target,
  and :complete is used in multiple steps with different targets.

  start → step_a ──(complete)──→ done_a
                  └─(reject)────→ rejected
        → step_b ──(complete)──→ done_b
                  └─(reject)────→ rejected
                  └─(back)──────→ step_a
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :step_a do
      transition :complete, to: :done_a
      transition :reject, to: :rejected
      transition :move_to_b, to: :step_b
    end

    step :step_b do
      transition :complete, to: :done_b
      transition :reject, to: :rejected
      transition :back, to: :step_a
    end

    step :done_a, terminal: true
    step :done_b, terminal: true
    step :rejected, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
  end
end
