defmodule AshWorkflow.Helper do
  alias AshWorkflow.Template.Result
  alias AshWorkflow.Dsl.Switch

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
    |> Enum.find(&(&1.step == step_name))
    |> case do
      nil -> nil
      %{value: value} -> value
    end
  end

  def get_result(workflow, step_name, sub_path) do
    case get_result(workflow, step_name) do
      nil -> nil
      %_struct{} = value -> get_in(Map.from_struct(value), sub_path)
      value -> get_in(value, sub_path)
    end
  end
end
