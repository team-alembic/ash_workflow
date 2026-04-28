defmodule AshWorkflowTest.FieldTimeoutWorkflow do
  @moduledoc """
  Workflow with a field-based timeout: fires based on an external datetime attribute.

  start → active ──(deactivate)──→ inactive
                 │
                 └─ 3 days after last_session_date ──→ inactive_review
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :active do
      transition :deactivate, to: :inactive

      timeout :inactivity,
        after: {3, :days},
        field: :last_session_date,
        transition_to: :inactive_review
    end

    step :inactive, terminal: true
    step :inactive_review, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :last_session_date]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :last_session_date, :utc_datetime_usec, public?: true
  end
end
