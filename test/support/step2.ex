defmodule AshWorkflowTest.Step2 do
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: :embedded

  attributes do
    uuid_v7_primary_key :id
  end
end
