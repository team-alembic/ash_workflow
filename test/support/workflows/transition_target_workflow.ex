defmodule AshWorkflowTest.TransitionTargetWorkflow do
  @moduledoc """
  Workflow for previewing where a transition would move a record.

  screening ──(advance)──→ activated   (when track == :direct)
                         → compliance  (when track == :standard)
            ──(refer)────→ activated   (when sponsor.name == "Direct")
                         → compliance  (when is_nil(sponsor_id))
            ──(escalate)─→ activated   (its condition always fails to evaluate)
            ──(reject)───→ rejected
  compliance ─(advance)──→ activated
             ─(reject)───→ rejected
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :screening do
      transition :advance do
        route :activated, when: expr(track == :direct)
        route :compliance, when: expr(track == :standard)
      end

      transition :refer do
        route :activated, when: expr(sponsor.name == "Direct")
        route :compliance, when: expr(is_nil(sponsor_id))
      end

      transition :escalate do
        route :activated,
          when:
            expr(
              error(Ash.Error.Changes.InvalidAttribute, %{field: :track, message: "unreadable"})
            )
      end

      transition :reject, to: :rejected
    end

    step :compliance do
      transition :advance, to: :activated
      transition :reject, to: :rejected
    end

    step :activated, terminal: true
    step :rejected, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title, :track, :sponsor_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true

    attribute :track, :atom,
      allow_nil?: true,
      constraints: [one_of: [:direct, :standard]],
      public?: true
  end

  relationships do
    belongs_to :sponsor, AshWorkflowTest.Reviewer, public?: true
  end
end
