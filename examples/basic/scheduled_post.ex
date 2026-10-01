defmodule BasicWorkflow.ScheduledPost do
  @moduledoc """
  A post that goes live at the time its author chose.

  Flow: scheduled → live → archived

  Demonstrates:
  - `fire_at`: the deadline is an instant stored on the record, `publish_at`
  - A wait state: nothing runs on entry to `:scheduled` and no caller can
    move the post, so the timeout is the only way out
  """

  use Ash.Resource,
    domain: BasicWorkflow.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "scheduled_posts"
    repo(Example.Repo)
  end

  workflow do
    step :scheduled do
      timeout :go_live do
        fire_at :publish_at
        transition_to :live
      end
    end

    step :live do
      transition :archive, to: :archived
    end

    step :archived, terminal: true
  end

  code_interface do
    define :schedule, action: :schedule
  end

  actions do
    defaults [:read]

    create :schedule do
      accept [:title, :publish_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false
    attribute :publish_at, :utc_datetime_usec, allow_nil?: false
  end
end
