defmodule Mix.Tasks.AshWorkflow.BackfillTransitionLog do
  @shortdoc "Seeds an approximate :initial transition-log row for existing records"

  @moduledoc """
  #{@shortdoc}.

  For every record of the given workflow resource that has no rows in its
  `transition_log`, inserts one row built from the record's current `state`
  and `state_entered_at`:

      transition_name: :initial
      triggered_by: :initial
      from_state: nil
      to_state: record's current state
      occurred_at: record's current state_entered_at

  Idempotent: a record that already has at least one log row is left alone,
  so running this task twice never doubles the seeded rows.

  History from before the log was enabled is not recoverable. This is a
  starting point, not real history — see the "Limits" section of the
  `workflow-history` guide.

  ## Example

  ```bash
  mix ash_workflow.backfill_transition_log MyApp.Ticket
  ```
  """

  use Mix.Task

  alias AshWorkflow.Info
  alias AshWorkflow.TransitionLog, as: TransitionLogHelpers

  @requirements ["app.start"]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    case argv do
      [resource_arg] ->
        resource_arg
        |> parse_module()
        |> backfill()

      _ ->
        Mix.raise("Usage: mix ash_workflow.backfill_transition_log MyApp.Ticket")
    end
  end

  defp parse_module(string), do: Module.concat([string])

  defp backfill(resource) do
    log = Info.transition_log(resource)

    if is_nil(log) do
      Mix.raise("""
      #{inspect(resource)} has no `transition_log` configured in its `workflow` block.

      Run `mix ash_workflow.gen.transition_log #{inspect(resource)}` first.
      """)
    end

    foreign_key = TransitionLogHelpers.foreign_key!(log.resource, resource)
    already_logged = already_logged_ids(log.resource, foreign_key)
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(resource)

    {seeded, skipped} =
      resource
      |> Ash.stream!(authorize?: false)
      |> Enum.reduce({0, 0}, fn record, {seeded, skipped} ->
        primary_key = TransitionLogHelpers.primary_key_value!(record)

        if MapSet.member?(already_logged, primary_key) do
          {seeded, skipped + 1}
        else
          seed_initial_row(log.resource, foreign_key, record, state_attribute)
          {seeded + 1, skipped}
        end
      end)

    Mix.shell().info("""
    Seeded #{seeded} approximate :initial row(s) for #{inspect(resource)}. \
    #{skipped} record(s) already had log rows and were left alone.

    WARNING: history before the transition log was enabled is not recoverable. \
    These seeded rows are approximate — built from each record's current state \
    and state_entered_at, not from any real transition history.
    """)
  end

  defp already_logged_ids(log_resource, foreign_key) do
    log_resource
    |> Ash.Query.select([foreign_key])
    |> Ash.stream!(authorize?: false)
    |> MapSet.new(&Map.fetch!(&1, foreign_key))
  end

  defp seed_initial_row(log_resource, foreign_key, record, state_attribute) do
    attrs = %{
      foreign_key => TransitionLogHelpers.primary_key_value!(record),
      from_state: nil,
      to_state: Map.get(record, state_attribute),
      transition_name: :initial,
      occurred_at: Map.fetch!(record, :state_entered_at),
      triggered_by: :initial
    }

    log_resource
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end
end
