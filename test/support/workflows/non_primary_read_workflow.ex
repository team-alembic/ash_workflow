defmodule AshWorkflowTest.NonPrimaryReadWorkflow do
  @moduledoc """
  Workflow whose resource already defines an action named `:read` that is not
  the primary read. The extension needs a read action for ash_oban, but adding
  its own `:read` here would collide with this one.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :processing do
      action :process
      on_success :done
    end

    step :done, terminal: true
  end

  actions do
    read :read do
      pagination keyset?: true, default_limit: 100, required?: false
    end

    read :everything do
      pagination keyset?: true, default_limit: 100, required?: false
    end

    create :create do
      accept [:title]
    end

    update :process do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
