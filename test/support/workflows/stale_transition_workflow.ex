defmodule AshWorkflowTest.StaleTransitionWorkflow do
  @moduledoc """
  A workflow for the stale-transition refusal: an undoable conditional
  `advance` whose routes read a nilable attribute and a relationship, a static
  undoable `reject` that updates atomically, a transition timeout and an
  automatic step.

  screening ──(advance, sponsor.name == "Fast")───────────────────→ fast_track
            ├─(advance, is_nil(path_type) or path_type == :agency)→ interviewing
            ├─(advance, path_type == :family)─────────────────────→ compliance
            ├─(reject, undoable)──────────────────────────────────→ rejected
            └─(timeout :expire)───────────────────────────────────→ expired
  interviewing ──(withdraw)──→ rejected
  interviewing | fast_track ──(advance)──→ compliance ──(automatic)──→ done
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    transition_log AshWorkflowTest.StaleTransitionLog

    undo do
    end

    step :screening do
      transition :advance do
        undoable? true
        route :fast_track, when: expr(sponsor.name == "Fast")
        route :interviewing, when: expr(is_nil(path_type) or path_type == :agency)
        route :compliance, when: expr(path_type == :family)
      end

      transition :reject, to: :rejected, undoable?: true
      timeout :expire, fire_after: {7, :days}, transition_to: :expired
    end

    step :interviewing do
      transition :advance, to: :compliance
      transition :withdraw, to: :rejected
    end

    step :fast_track do
      transition :advance, to: :compliance
    end

    step :compliance, action: :run_checks, on_success: :done

    step :done, terminal: true
    step :rejected, terminal: true
    step :expired, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :path_type, :sponsor_id]
    end

    update :classify do
      accept [:path_type]
    end

    update :edit_note do
      accept [:note]
    end

    update :run_checks do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :path_type, :atom, constraints: [one_of: [:agency, :family]], public?: true
    attribute :note, :string, public?: true
  end

  relationships do
    belongs_to :sponsor, AshWorkflowTest.Reviewer, public?: true, attribute_writable?: true
  end
end
