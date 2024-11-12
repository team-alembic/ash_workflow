defmodule AshWorkflowTest.Step1 do
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_v7_primary_key :id
  end
end
