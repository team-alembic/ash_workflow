defmodule AshWorkflowTest.SharedConditionalWorkflow do
  @moduledoc """
  Workflow where :advance is shared across multiple steps, and one step
  uses conditional routing while others use static targets.

  This reproduces the bug where a conditional route (e.g. path_type check)
  from one step would incorrectly match when evaluated from a different step,
  because the route wasn't scoped to its originating step.

  start → screening ──(advance)──→ review
        → review    ──(advance)──→ compliance
        → compliance──(advance)──→ training (when path_type == :full)
                                 → fast_track (when path_type == :abbreviated)
        → training  ──(advance)──→ done
        → fast_track──(advance)──→ done
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :screening do
      manual true
      transition :advance, to: :review
    end

    step :review do
      manual true
      transition :advance, to: :compliance
    end

    step :compliance do
      manual true

      transition :advance do
        route :training, when: expr(path_type == :full)
        route :fast_track, when: expr(path_type == :abbreviated)
      end
    end

    step :training do
      manual true
      transition :advance, to: :done
    end

    step :fast_track do
      manual true
      transition :advance, to: :done
    end

    step :done, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false

    attribute :path_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:full, :abbreviated]],
      public?: true
  end
end
