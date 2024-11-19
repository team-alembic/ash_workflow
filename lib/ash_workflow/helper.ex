defmodule AshWorkflow.Helper do
  alias AshWorkflow.Template.Result
  alias AshWorkflow.Dsl.Switch

  require Ash.Query

  def sub_workflow(%Ash.Changeset{} = changeset, step_name, sub_workflow_module, opts),
    do: sub_workflow(changeset.data, step_name, sub_workflow_module, opts)

  def sub_workflow(workflow, step_name, sub_workflow_module, opts) do
    case get_result(workflow, step_name) do
      nil ->
        :erlang.apply(sub_workflow_module, :start!, [
          opts
        ])

      workflow ->
        workflow
    end
  end

  def step_from_switch(
        switch,
        %Ash.Changeset{} = changeset
      ),
      do: step_from_switch(switch, changeset.data)

  def step_from_switch(
        %Switch{matches: matches, on: on} = step,
        workflow
      ) do
    case Enum.find(matches, fn
           %{predicate: predicate} ->
             on =
               case on do
                 %Result{name: name, sub_path: sub_path} ->
                   get_result(workflow, name, sub_path)

                 inital ->
                   inital
               end

             predicate.(on)
         end) do
      nil -> step.default.step
      %{step: step} -> step
    end
  end

  def get_result(workflow_or_changeset, step_name, sub_path \\ [])

  def get_result(%Ash.Changeset{} = changeset, step_name, sub_path),
    do: get_result(changeset.data, step_name, sub_path)

  def get_result(workflow, step_name, []) do
    workflow
    |> Map.get(:results)
    |> List.wrap()
    |> Enum.find(&(&1.value.name == step_name))
    |> case do
      %{type: :embed, value: %{resource: resource, embed: embed}} ->
        action_inputs =
          resource |> Ash.Resource.Info.action_inputs(:create) |> Enum.filter(&is_atom/1)

        params = Map.take(embed, action_inputs)
        private_params = Map.drop(embed, action_inputs)

        private_params
        |> Enum.reduce(
          Ash.Changeset.for_create(
            resource,
            :create,
            params
          ),
          fn {key, value}, changeset ->
            Ash.Changeset.force_change_attribute(changeset, key, value)
          end
        )
        |> Ash.create!()

      %{type: :reference, value: %{resource: resource, filter: filter}} ->
        %{name: read} = Ash.Resource.Info.primary_action!(resource, :read)

        resource
        |> Ash.Query.for_read(read)
        |> Ash.Query.do_filter(filter)
        |> Ash.read_one!()

      nil ->
        nil
    end
  end

  def get_result(workflow, step_name, sub_path) do
    case get_result(workflow, step_name) do
      nil -> nil
      %_struct{} = value -> get_in(Map.from_struct(value), sub_path)
      value -> get_in(value, sub_path)
    end
  end

  def to_result(:ok, _), do: nil

  def to_result(%resource{} = result, step) do
    to_result(Ash.Resource.Info.data_layer(resource), result, step)
  end

  defp to_result(Ash.DataLayer.Simple, %resource{} = result, step) do
    embed =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.into(%{}, fn %{name: name} ->
        {name, Map.get(result, name)}
      end)

    %{type: :embed, name: step.name, resource: resource, embed: embed}
  end

  defp to_result(_data_layer, %resource{} = result, step) do
    primary_key_match = Map.take(result, Ash.Resource.Info.primary_key(resource))

    %{
      type: :reference,
      name: step.name,
      filter: primary_key_match,
      resource: resource
    }
  end
end
