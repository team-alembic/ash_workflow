defmodule AshWorkflowTest.Candidate do
  @moduledoc """
  A plain resource holding a time zone, for
  `AshWorkflowTest.RelatedZoneWorkflow` to reach through a relationship and
  read.
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
      primary? true
      accept [:name, :time_zone]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :time_zone, :string, allow_nil?: false, public?: true
  end
end
