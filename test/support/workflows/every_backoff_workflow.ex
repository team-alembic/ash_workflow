defmodule AshWorkflowTest.EveryBackoffWorkflow do
  @moduledoc """
  Three `every` entities on one step, one per new bound: `:capped` stops after
  two fires, `:fixed` adds 2 hours to every gap after the first, and
  `:exponential` adds `n^4 + 15` seconds after fire `n`.

  Uses `AshWorkflow.Scheduler.Precise` so `Precise.run_due/2` drives the
  firing synchronously. `set_clock` forces any column, so a test can place a
  record on either side of a gap without a clock passing. `:send_capped`
  counts in Elixir and so runs `AshWorkflow.Changes.RecordEvent`'s `change/3`,
  while the other two actions are atomic and run its `atomic/3`.

      waiting ──(pause)──▶ paused ──(resume)──▶ waiting
              │
              ├─ every hour, at most twice ──▶ send_capped
              ├─ every hour, +2 hours after the first ──▶ send_fixed
              └─ every hour, +n^4+15 seconds after fire n ──▶ send_exponential
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :pause, to: :paused

      every :capped do
        interval {1, :hours}
        action :send_capped
        max_fires(2)
      end

      every :fixed do
        interval {1, :hours}
        action :send_fixed
        backoff {2, :hours}
      end

      every :exponential do
        interval {1, :hours}
        action :send_exponential
        backoff :exponential
      end
    end

    step :paused do
      transition :resume, to: :waiting
    end
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title]
    end

    update :send_capped do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(
          changeset,
          :capped_count,
          Ash.Changeset.get_data(changeset, :capped_count) + 1
        )
      end
    end

    update :send_fixed do
      accept []
    end

    update :send_exponential do
      accept []
    end

    update :set_clock do
      accept []
      argument :values, :map, allow_nil?: false
      require_atomic? false

      change fn changeset, _ctx ->
        changeset
        |> Ash.Changeset.get_argument(:values)
        |> Enum.reduce(changeset, fn {field, value}, changeset ->
          Ash.Changeset.force_change_attribute(changeset, field, value)
        end)
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :capped_count, :integer, allow_nil?: false, default: 0, public?: true
  end
end
