defmodule AshWorkflow.Resources.Result.Embed do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :name, :atom do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :type, :atom do
      writable? false
      default :embed
    end

    attribute :resource, :atom do
      allow_nil? false
      public? true
    end

    attribute :embed, :map do
      allow_nil? false
      public? true
    end
  end
end
