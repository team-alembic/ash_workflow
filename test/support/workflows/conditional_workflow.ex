defmodule AshWorkflowTest.ConditionalWorkflow do
  @moduledoc """
  Workflow with conditional transitions: routes to different states based on path_type.

  start → compliance ──(complete)──→ training       (when path_type == :full)
                                   → fast_track     (when path_type == :abbreviated)
                      └─(reject_at_compliance)──→ rejected
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :compliance do
      transition :complete do
        route :training, when: expr(path_type == :full)
        route :fast_track, when: expr(path_type == :abbreviated)
      end

      transition :reject_at_compliance, to: :rejected
    end

    step :training do
      transition :finish_training, to: :done
    end

    step :fast_track do
      transition :finish_fast_track, to: :done
    end

    step :done, terminal: true
    step :rejected, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :path_type]
    end
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
