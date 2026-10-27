defmodule AshWorkflow.Scheduler.ObanActorTest do
  @moduledoc """
  `AshWorkflow.Scheduler.Oban`'s `:actor` option becomes every generated
  trigger's `default_actor`, which is the actor a cron-fired scheduler reads
  with and a worker falls back to.
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.Postgres.ActorScheduledWorkflow
  alias AshWorkflowTest.SystemActor

  defp default_actors(resource) do
    resource
    |> AshOban.Info.oban_triggers()
    |> Enum.map(& &1.default_actor)
  end

  test "every trigger carries the configured actor" do
    assert [_ | _] = actors = default_actors(ActorScheduledWorkflow)
    assert Enum.all?(actors, &(&1 == %SystemActor{reason: "submission sync"}))
  end

  test "triggers carry no actor when the option is unset" do
    assert [_ | _] = actors = default_actors(AshWorkflowTest.CheckIntervalWorkflow)
    assert Enum.all?(actors, &is_nil/1)
  end
end
