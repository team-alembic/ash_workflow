defmodule AshWorkflowTest.SharedTimeoutNameWorkflow do
  @moduledoc """
  Two steps that each declare a timeout called `:sla_breach`.

  Timeout names are scoped to their step, the way transition names are, so
  modelling "each queue has its own SLA" does not require inventing globally
  unique timeout names.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :triaging do
      transition :to_urgent, to: :urgent
      transition :to_standard, to: :standard
    end

    step :urgent do
      transition :resolve, to: :resolved

      timeout :sla_breach, after: {1, :hours}, transition_to: :breached
      timeout :warn, after: {30, :minutes}, action: :send_warning
    end

    step :standard do
      transition :resolve, to: :resolved

      timeout :sla_breach, after: {2, :days}, transition_to: :breached
      timeout :warn, after: {1, :days}, action: :send_warning
    end

    step :resolved, terminal: true
    step :breached, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end

    update :send_warning do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
  end
end
