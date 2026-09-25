defmodule AshWorkflowTest.ChartKeywordWorkflow do
  @moduledoc """
  Step names that are Mermaid keywords, for `AshWorkflow.Charts.Mermaid`.

  start → note ──(close)──→ end
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :note do
      transition :close, to: :end
    end

    step :end, terminal: true
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
    attribute :title, :string, allow_nil?: false
  end
end
