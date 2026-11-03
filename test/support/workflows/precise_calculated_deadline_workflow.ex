defmodule AshWorkflowTest.PreciseCalculatedDeadlineWorkflow do
  @moduledoc """
  A `fire_at` deadline read from an expression calculation over a stored
  attribute, under `AshWorkflow.Scheduler.Precise`.

  The record enters `:active` on create, and nothing the create returns has
  `expiring_at` loaded.

      active ──(expiring_at passes)──▶ expired
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :active do
      timeout :expire do
        fire_at :expiring_at
        transition_to :expired
      end
    end

    step :expired, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      accept [:expires_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  calculations do
    calculate :expiring_at, :utc_datetime_usec, expr(datetime_add(expires_at, -1, :day))
  end
end
