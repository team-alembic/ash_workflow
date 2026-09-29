defmodule AshWorkflowTest.SkipOtherActorsWorkflow do
  @moduledoc """
  A workflow whose log records only `AshWorkflowTest.Reviewer` actors, and
  whose undo is restricted to the actor that made the transition.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    transition_log AshWorkflowTest.SkipOtherActorsLog do
      belongs_to_actor :user, AshWorkflowTest.Reviewer, skip_other_actors?: true
    end

    undo do
      same_actor? true
    end

    step :review do
      transition :approve, to: :done, undoable?: true
    end

    step :done, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
