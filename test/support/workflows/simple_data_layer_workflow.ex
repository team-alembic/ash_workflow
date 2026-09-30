defmodule AshWorkflowTest.SimpleDataLayerWorkflow do
  @moduledoc """
  A workflow on `Ash.DataLayer.Simple`, which cannot filter an update, so its
  transitions pin nothing.

  screening ──(advance, path_type == :family)───────────────────────→ compliance
            ├─(advance, is_nil(path_type) or path_type == :agency)→ interviewing
            └─(reject)──────────────────────────────────────────────→ rejected
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :screening do
      transition :advance do
        route :compliance, when: expr(path_type == :family)
        route :interviewing, when: expr(is_nil(path_type) or path_type == :agency)
      end

      transition :reject, to: :rejected
    end

    step :interviewing, terminal: true
    step :compliance, terminal: true
    step :rejected, terminal: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:path_type]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :path_type, :atom, constraints: [one_of: [:agency, :family]], public?: true
  end
end
