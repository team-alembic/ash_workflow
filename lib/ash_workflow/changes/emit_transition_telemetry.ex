defmodule AshWorkflow.Changes.EmitTransitionTelemetry do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def atomic(changeset, opts, _context) do
    transition_name = opts[:transition_name]
    trigger = opts[:trigger]
    to_state = opts[:to_state]

    from_state = if changeset.data, do: Map.get(changeset.data, :state)

    metadata = %{
      resource: changeset.resource,
      workflow_id: extract_workflow_id(changeset),
      from_state: from_state,
      to_state: to_state,
      action: changeset.action.name,
      transition_name: transition_name,
      trigger: trigger
    }

    start_time = System.monotonic_time()
    AshWorkflow.Telemetry.emit_transition_start(metadata)

    changeset =
      Ash.Changeset.after_action(changeset, fn _changeset, result ->
        duration = System.monotonic_time() - start_time
        resolved_to = Map.get(result, :state, to_state)

        AshWorkflow.Telemetry.emit_transition_stop(
          %{metadata | to_state: resolved_to},
          duration
        )

        {:ok, result}
      end)

    {:ok, changeset}
  end

  @impl true
  def change(changeset, opts, _context) do
    transition_name = opts[:transition_name]
    trigger = opts[:trigger]
    to_state = opts[:to_state]

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      from_state = if changeset.data, do: Map.get(changeset.data, :state)

      metadata = %{
        resource: changeset.resource,
        workflow_id: extract_workflow_id(changeset),
        from_state: from_state,
        to_state: to_state,
        action: changeset.action.name,
        transition_name: transition_name,
        trigger: trigger
      }

      AshWorkflow.Telemetry.emit_transition_start(metadata)

      Ash.Changeset.put_context(changeset, :ash_workflow_telemetry, %{
        metadata: metadata,
        start_time: System.monotonic_time()
      })
    end)
    |> Ash.Changeset.after_action(fn changeset, result ->
      case changeset.context[:ash_workflow_telemetry] do
        %{metadata: metadata, start_time: start_time} ->
          duration = System.monotonic_time() - start_time
          resolved_to = Map.get(result, :state, metadata.to_state)

          AshWorkflow.Telemetry.emit_transition_stop(
            %{metadata | to_state: resolved_to},
            duration
          )

        _ ->
          :ok
      end

      {:ok, result}
    end)
  end

  defp extract_workflow_id(changeset) do
    case Ash.Resource.Info.primary_key(changeset.resource) do
      [key] -> Ash.Changeset.get_attribute(changeset, key)
      keys -> Map.new(keys, &{&1, Ash.Changeset.get_attribute(changeset, &1)})
    end
  end
end
