defmodule AshWorkflowTest.ExprCalcTimeoutWorkflow do
  @moduledoc """
  Workflow whose timeout measures against an expression calculation.

  Expression calculations inline into the trigger's `where` clause, so unlike
  module calculations they are valid timeout fields.

  start → active ──(deactivate)──→ inactive
                 │
                 └─ 3 days after grace_period_start ──→ inactive_review
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :active do
      transition :deactivate, to: :inactive

      timeout :inactivity,
        after: {3, :days},
        field: :grace_period_start,
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

  calculations do
    calculate :grace_period_start,
              :utc_datetime_usec,
              expr(fragment("coalesce(?, ?)", last_session_date, state_entered_at))
  end
end
