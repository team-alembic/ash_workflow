defmodule AshWorkflow.Resources.Param do
  use Ash.Resource,
    data_layer: :embedded

  actions do
    create :from_action_input do
      argument :action_input, :struct do
        allow_nil? false
      end

      change fn changeset, _ ->
        %{name: name, type: type, allow_nil?: allow_nil?} = Ash.Changeset.get_argument(changeset, :action_input)


        changeset
        |> Ash.Changeset.change_attribute(:name, name)
        |> Ash.Changeset.change_attribute(:type, type)
        |> Ash.Changeset.change_attribute(:required, not allow_nil?)
      end
    end
  end

  attributes do
    attribute :name, :atom do
      primary_key? true
      allow_nil? false
    end

    attribute :type, :atom do
      allow_nil? false
    end

    attribute :required, :boolean do
      allow_nil? false
    end
  end
end
