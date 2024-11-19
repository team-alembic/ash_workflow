defmodule AshWorkflow.Calculations.Helper do
  alias AshWorkflow.Dsl.ActionStep
  alias AshWorkflow.Resources.Step

  def create_step(%ActionStep{} = step, opts \\ []) do
    %{accept: accept, arguments: arguments} =
      step.resource
      |> Ash.Resource.Info.action(step.action)

    params =
      accept
      |> Enum.map(&Ash.Resource.Info.attribute(step.resource, &1))
      |> Enum.concat(arguments)
      |> Enum.map(&create_params/1)

    input = %{
      name: step.name,
      resource: step.resource,
      action: step.action,
      params: params
    }

    Step
    |> Ash.Changeset.for_create(:create, input, opts)
    |> Ash.create!()
  end

  defp create_params(%{name: name, type: type, allow_nil?: allow_nil?}) do
    %{name: name, type: type, required: not allow_nil?}
  end
end
