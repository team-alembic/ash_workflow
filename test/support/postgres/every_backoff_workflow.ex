defmodule AshWorkflowTest.Postgres.EveryBackoffWorkflow do
  @moduledoc """
  `max_fires` and `backoff` against a real database and real Oban triggers.
  Every action is atomic, so `AshWorkflow.Changes.RecordEvent` increments each
  fire count in SQL.

      waiting ──(resolve)──▶ resolved
              │
              ├─ every hour, at most twice ──▶ send_capped
              ├─ every hour, +2 hours after the first ──▶ send_fixed
              └─ every hour, +n^4+15 seconds after fire n ──▶ send_exponential
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "every_backoff_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :waiting do
      transition :resolve, to: :resolved

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

    step :resolved, terminal: true
  end

  code_interface do
    define :submit
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:title]
    end

    update :send_capped do
      accept []
    end

    update :send_fixed do
      accept []
    end

    update :send_exponential do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
