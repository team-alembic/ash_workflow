defmodule AshWorkflowTest.FireAtWorkflow do
  @moduledoc """
  Timeouts that name the field holding their deadline, under
  `AshWorkflow.Scheduler.Precise`.

  `:waiting` reads a plain attribute, and `:calculated` reads an expression
  calculation, which is the case `AshWorkflow.Scheduler.due_at/2` cannot read
  off an unloaded record.

      waiting ──(next_check_at passes)──▶ reviewed
      calculated ──(effective_check_at passes)──▶ reviewed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :start_calculating, to: :calculated

      timeout :review do
        fire_at :next_check_at
        transition_to :reviewed
      end
    end

    step :calculated do
      timeout :calculated_review do
        fire_at :effective_check_at
        transition_to :reviewed
      end
    end

    step :reviewed, terminal: true
  end

  code_interface do
    define :create
    define :start_calculating
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title, :next_check_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :next_check_at, :utc_datetime_usec, public?: true
  end

  calculations do
    calculate :effective_check_at,
              :utc_datetime_usec,
              expr(if is_nil(next_check_at), do: state_entered_at, else: next_check_at)
  end
end
