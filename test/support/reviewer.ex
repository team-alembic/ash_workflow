defmodule AshWorkflowTest.Reviewer do
  @moduledoc """
  A minimal actor resource, used only to exercise `belongs_to_actor` on a
  `transition_log`.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end
end
