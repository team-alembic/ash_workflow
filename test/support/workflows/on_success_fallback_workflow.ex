defmodule AshWorkflowTest.OnSuccessFallbackWorkflow do
  @moduledoc """
  A step mixing conditional `on_success` entries with a trailing unconditional
  fallback: high-priority tickets go to `escalated`, everything else falls
  through to `queued`.

  start → triaging ──(run_triage, priority == :high)──▶ escalated
                    └─(run_triage, fallback)───────────▶ queued
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :triaging do
      action :run_triage
      on_success :escalated, when: expr(priority == :high)
      on_success :queued
    end

    step :escalated, terminal: true
    step :queued, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:priority]
    end

    update :run_triage do
      accept []
      require_atomic? false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :priority, :atom, constraints: [one_of: [:high, :normal, :low]], public?: true
  end
end
