defmodule AshWorkflow.Resources.Step.FromStep do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    step = Ash.Changeset.get_argument(changeset, :step)

    %{accept: accept, arguments: arguments} =
      step.resource
      |> Ash.Resource.Info.action(step.action)

  params  =
      accept
      |> Enum.map(&Ash.Resource.Info.attribute(step.resource, &1))
      |> Enum.concat(arguments)
       |> Enum.map(&create_param_resource/1)



    changeset
    |> Ash.Changeset.change_attribute(:name, step.name)
    |> Ash.Changeset.change_attribute(:resource, step.resource)
    |> Ash.Changeset.change_attribute(:action, step.action)
    |> Ash.Changeset.change_attribute(:params, params)

  end

  defp create_param_resource(action_input) do
    AshWorkflow.Resources.Param
    |> Ash.Changeset.for_create(:from_action_input, %{action_input: action_input})
    |> Ash.create!()
  end
end
