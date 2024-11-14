defmodule AshWorkflow.Changes.ExecuteStep do
  alias AshWorkflow.Entities.Workflow
  alias AshWorkflow.Entities.Step
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    current_step = Ash.Changeset.get_data(changeset, :current_step)
    next_state = AshWorkflow.Info.get_next_step(changeset.data, current_step)

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      case AshWorkflow.Info.steps(changeset.data) |> Enum.find(&(&1.name == current_step)) do
        %Step{resource: resource, action: action} ->
          action = Ash.Resource.Info.action(resource, action)

          run_action(
            resource,
            action,
            Ash.Changeset.get_argument(changeset, :params),
            Ash.Context.to_opts(context)
          )

        %Workflow{workflow: workflow_module} ->
          # TODO: we need to persist the workflow somehow to be able to resume it
          workflow =
            :erlang.apply(workflow_module, :start!, [
              Ash.Context.to_opts(context)
            ])

          :erlang.apply(workflow_module, :next!, [
            workflow,
            Ash.Changeset.get_argument(changeset, :params) || %{},
            Ash.Context.to_opts(context)
          ])
      end

      changeset
    end)
    |> AshStateMachine.transition_state(next_state)
  end

  defp run_action(resource, %{type: :create, name: name}, params, opts) do
    resource
    |> Ash.Changeset.for_create(name, params, opts)
    |> Ash.create!()
  end

  defp run_action(resource, %{type: :update, name: name}, params, opts) do
    resource
    |> Ash.Changeset.for_update(name, params, opts)
    |> Ash.update!()
  end

  defp run_action(resource, %{type: :destroy, name: name}, params, opts) do
    resource
    |> Ash.Changeset.for_destroy(name, params, opts)
    |> Ash.destroy!()
  end
end
