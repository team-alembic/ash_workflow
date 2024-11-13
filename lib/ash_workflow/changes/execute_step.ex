defmodule AshWorkflow.Changes.ExecuteStep do
  use Ash.Resource.Change

  @impl true
  def atomic(changeset, _opts, context) do
    {:atomic,
     Ash.Changeset.after_action(changeset, fn changeset, record ->
       dbg([changeset.data, record])

       %{resource: resource, action: action} =
         Enum.at(
           AshWorkflow.Calculations.Steps.calculate(record),
           changeset.data.current_step_index
         )

       action = Ash.Resource.Info.action(resource, action)

       run_action(
         resource,
         action,
         Ash.Changeset.get_argument(changeset, :params),
         Ash.Context.to_opts(context)
       )

       {:ok, record}
     end), %{current_step_index: expr(current_step_index + 1)}}
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
