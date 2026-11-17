defmodule AshWorkflow.MultipleInitialRuntimeTest do
  @moduledoc """
  A create that names a later initial step with `transition_state/1` starts
  there exactly as a create into the default initial step would.
  """
  use AshWorkflowTest.EtsCase, async: true
  use Oban.Testing, repo: AshWorkflowTest.Repo, prefix: "public"

  import Ash.Signals.Test

  alias AshWorkflow.Charts.Dot
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Json
  alias AshWorkflow.Clarity.Content.WorkflowOverview
  alias AshWorkflowTest.MultipleInitialRuntimeWorkflow, as: Workflow
  alias AshWorkflowTest.MultipleInitialSignals, as: Signals
  alias Clarity.Vertex.Ash.Resource, as: ResourceVertex

  defp reload(record), do: Ash.get!(Workflow, record.id, authorize?: false)

  defp trigger(name) do
    Workflow
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.name == name))
  end

  defp intake_worker,
    do: Enum.find(AshOban.Info.oban_triggers(Workflow), &(&1.action == :process_intake)).worker

  defp matching_ids(trigger) do
    Workflow
    |> Ash.Query.do_filter(trigger.where)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  defp backdate!(record, days_ago) do
    record
    |> Ash.Changeset.for_update(:touch, %{})
    |> Ash.Changeset.force_change_attribute(
      :state_entered_at,
      DateTime.add(DateTime.utc_now(), -days_ago, :day)
    )
    |> Ash.update!()
  end

  describe "the transition log" do
    test "a create into a later initial step writes an :initial row to that step with no from_state" do
      record = Workflow.create_at_parked!(%{title: "test"})

      assert [row] = Workflow.history(record)
      assert row.from_state == nil
      assert row.to_state == :parked
      assert row.transition_name == :create_at_parked
      assert row.triggered_by == :initial
    end
  end

  describe "step emits" do
    setup :capture_signals

    test "a create into a later initial step emits that step's signal and not the first step's" do
      %{id: id} = Workflow.create_at_intake!(%{title: "test"})

      assert_signal_emitted(Signals, :intake_started, %{id: ^id, to_state: :intake})
      refute_signal_emitted(Signals, :drafting_started)
    end
  end

  describe "an automatic later initial step" do
    test "a create into it queues its action" do
      record = Workflow.create_at_intake!(%{title: "test"})

      assert_enqueued(worker: intake_worker(), args: %{"primary_key" => %{"id" => record.id}})
    end

    test "running the queued job moves the record on" do
      record = Workflow.create_at_intake!(%{title: "test"})

      assert %{success: 1} = Oban.drain_queue(queue: :workflow)
      assert reload(record).state == :review
    end
  end

  describe "a wait-state later initial step" do
    test "its timeout matches only once state_entered_at is older than fire_after" do
      record = Workflow.create_at_parked!(%{title: "test"})
      release = trigger(:__timeout_trigger_parked_release)

      refute record.id in matching_ids(release)

      backdate!(record, 4)
      assert record.id in matching_ids(release)
    end

    test "the timeout moves the record to its target" do
      record = Workflow.create_at_parked!(%{title: "test"})

      record = Ash.update!(record, action: :__timeout_parked_release)
      assert record.state == :drafting
    end
  end

  describe "an initial step another step leads into" do
    test "a record can start there and return there" do
      record = Workflow.create_at_intake!(%{title: "test"})
      record = Ash.update!(record, action: :process_intake)
      record = Ash.update!(record, action: :reopen)

      assert record.state == :intake

      assert Enum.map(Workflow.history(record), &{&1.from_state, &1.to_state, &1.triggered_by}) ==
               [
                 {nil, :intake, :initial},
                 {:intake, :review, :automatic},
                 {:review, :intake, :manual}
               ]
    end
  end

  describe "charts" do
    test "the JSON graph marks every initial step" do
      initial =
        for node <- Json.to_map(Graph.build(Workflow))["nodes"], node["initial"], do: node["id"]

      assert initial == ["drafting", "intake", "parked"]
    end

    test "the DOT graph draws a start edge to every initial step" do
      dot = Workflow |> Graph.build() |> Dot.render([]) |> IO.iodata_to_binary()

      assert dot =~ ~s("start" -> "step_drafting";)
      assert dot =~ ~s("start" -> "step_intake";)
      assert dot =~ ~s("start" -> "step_parked";)
    end
  end

  describe "the Clarity workflow overview" do
    test "lists every initial step under the plural label" do
      {:markdown, render} =
        WorkflowOverview.render_static(
          %ResourceVertex{resource: Workflow},
          nil
        )

      row =
        render.(%{})
        |> IO.iodata_to_binary()
        |> String.split("\n")
        |> Enum.find(&String.contains?(&1, "Initial step"))

      assert row =~ "Initial steps"
      assert row =~ "`drafting`"
      assert row =~ "`intake`"
      assert row =~ "`parked`"
    end
  end
end
