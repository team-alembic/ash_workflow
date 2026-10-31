defmodule AshWorkflowTest.Postgres.ActorScheduledWorkflow do
  @moduledoc """
  An automatic step on a resource whose read policy needs an actor, with the
  actor supplied by `AshWorkflow.Scheduler.Oban`'s `:actor` option.

      pending ──(submit)──▶ submitted

  `submit` records the actor's `reason` in `submitted_by`, so a test can see
  which actor the worker ran the step as.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "actor_scheduled_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    scheduler {AshWorkflow.Scheduler.Oban,
               actor: %AshWorkflowTest.SystemActor{reason: "submission sync"}}

    step :pending do
      action :submit
      on_success :submitted
    end

    step :submitted, terminal: true
  end

  actions do
    defaults [:read, create: [:title]]

    update :submit do
      accept []
      change set_attribute(:submitted_by, actor(:reason))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:reason, "submission sync")
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :submitted_by, :string, public?: true
  end
end
