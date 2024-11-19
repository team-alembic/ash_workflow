defmodule AshWorkflow.Changes.ExecuteStep do
  use Ash.Resource.Change

  alias AshWorkflow.Template.Result
  alias AshWorkflow.Dsl.{ActionStep, WorkflowStep, Switch}

  import AshWorkflow.Helper

  @impl true
  def change(changeset, _opts, context) do
    current_state = Ash.Changeset.get_data(changeset, :state)
    next_state = AshWorkflow.Info.get_next_state(changeset.data, current_state)

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      step = AshWorkflow.Info.steps(changeset.data) |> Enum.find(&(&1.name == current_state))

      run_step(step, changeset, context, current_state, next_state)
    end)
  end

  defp run_step(
         %ActionStep{resource: resource, action: action} = step,
         changeset,
         context,
         _current_state,
         next_state
       ) do
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
        (result |> to_result(step) |> List.wrap())
    )
  end

  defp run_step(
         %Switch{} = step,
         changeset,
         context,
         current_state,
         next_state
       ) do
    step =
      step_from_switch(
        step,
        changeset,
        Ash.Context.to_opts(context)
      )

    run_step(step, changeset, context, current_state, next_state)
  end

  defp run_step(
         %WorkflowStep{workflow: workflow_module, name: name} = step,
         changeset,
         context,
         _current_state,
         next_state
       ) do
    workflow =
      sub_workflow(
        changeset,
        name,
        workflow_module,
        Ash.Context.to_opts(context)
      )

    workflow =
      :erlang.apply(workflow_module, :next!, [
        workflow,
        Ash.Changeset.get_argument(changeset, :params) || %{},
        Ash.Context.to_opts(context)
      ])

    changeset =
      if workflow.state == :done do
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
          to_result(workflow, step)
        ]
    )
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
          get_result(changeset, name, sub_path, opts)

        inital ->
          inital
      end

    inital
    |> Ash.Changeset.for_update(name, params, opts)
    |> Ash.update!()
  end

  defp run_action(
         _resource,
         %{type: :destroy, name: name},
         params,
         opts,
         %{initial: inital},
         changeset
       ) do
    inital =
      case inital do
        %Result{name: name, sub_path: sub_path} ->
          get_result(changeset, name, sub_path, opts)

        inital ->
          inital
      end

    inital
    |> Ash.Changeset.for_destroy(name, params || %{}, opts)
    |> Ash.destroy!()
  end
end
