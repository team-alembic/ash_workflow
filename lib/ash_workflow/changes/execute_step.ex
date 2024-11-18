defmodule AshWorkflow.Changes.ExecuteStep do
  alias AshWorkflow.Template.Result
  alias AshWorkflow.Entities.WorkflowStep
  alias AshWorkflow.Entities.ActionStep
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    current_step = Ash.Changeset.get_data(changeset, :current_step)
    next_state = AshWorkflow.Info.get_next_step(changeset.data, current_step)

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      case AshWorkflow.Info.steps(changeset.data) |> Enum.find(&(&1.name == current_step)) do
        %ActionStep{resource: resource, action: action, name: name} = step ->
          action = Ash.Resource.Info.action(resource, action)

          result =
            run_action(
              resource,
              action,
              Ash.Changeset.get_argument(changeset, :params),
              Ash.Context.to_opts(context),
              step,
              changeset
            )

          changeset
          |> AshStateMachine.transition_state(next_state)
          |> Ash.Changeset.force_change_attribute(
            :results,
            (Ash.Changeset.get_data(changeset, :results) || []) ++
              [
                %{step: name, value: result}
              ]
          )

        %WorkflowStep{workflow: workflow_module, name: name} ->
          # TODO: we need to persist the workflow somehow to be able to resume it
          workflow =
            case get_result(changeset, name) do
              nil ->
                :erlang.apply(workflow_module, :start!, [
                  Ash.Context.to_opts(context)
                ])

              workflow ->
                workflow
            end

          dbg(workflow)

          workflow =
            :erlang.apply(workflow_module, :next!, [
              workflow,
              Ash.Changeset.get_argument(changeset, :params) || %{},
              Ash.Context.to_opts(context)
            ])

          dbg(workflow |> Ash.load!(:steps))

          changeset =
            if workflow.current_step == :done do
              changeset
              |> AshStateMachine.transition_state(next_state)
            else
              changeset
            end

          changeset
          |> Ash.Changeset.force_change_attribute(
            :results,
            (Ash.Changeset.get_data(changeset, :results) || []) ++
              [
                %{step: name, value: workflow}
              ]
          )
      end
    end)
  end

  defp run_action(resource, %{type: :create, name: name}, params, opts, _step, _changetset) do
    resource
    |> Ash.Changeset.for_create(name, params, opts)
    |> Ash.create!()
  end

  defp run_action(
         _resource,
         %{type: :update, name: name},
         params,
         opts,
         %{initial: inital},
         changeset
       ) do
    inital =
      case inital do
        %Result{name: name, sub_path: sub_path} ->
          get_result(changeset, name, sub_path)

        inital ->
          inital
      end

    inital
    |> Ash.Changeset.for_update(name, params, opts)
    |> Ash.update!()
  end

  defp run_action(resource, %{type: :destroy, name: name}, params, opts, _step, _changetset) do
    resource
    |> Ash.Changeset.for_destroy(name, params, opts)
    |> Ash.destroy!()
  end

  defp get_result(changeset, step_name, sub_path \\ [])

  defp get_result(changeset, step_name, []) do
    changeset
    |> Ash.Changeset.get_data(:results)
    |> List.wrap()
    |> Enum.find(&(&1.step == step_name))
    |> case do
      nil -> nil
      %{value: value} -> value
    end
  end

  defp get_result(changeset, step_name, sub_path) do
    case get_result(changeset, step_name) do
      nil -> nil
      value -> get_in(value, sub_path)
    end
  end
end
