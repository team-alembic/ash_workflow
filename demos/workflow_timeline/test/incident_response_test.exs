defmodule WorkflowTimeline.IncidentResponseTest do
  use WorkflowTimeline.DataCase, async: false

  alias WorkflowTimeline.IncidentResponse
  alias WorkflowTimeline.IncidentResponse.{Incident, Responder}

  setup do
    Application.put_env(:workflow_timeline, :fast_tests, true)
    on_exit(fn -> Application.put_env(:workflow_timeline, :fast_tests, false) end)
    :ok
  end

  defp report!(title \\ "Checkout latency spike") do
    {:ok, incident} = IncidentResponse.report(title, "it's slow")
    incident
  end

  defp responder!(name \\ "Priya") do
    Responder
    |> Ash.Changeset.for_create(:create, %{name: name, team: "SRE"})
    |> Ash.create!()
  end

  defp names(history) do
    Enum.map(history, &{&1.from_state, &1.to_state, &1.transition_name, &1.triggered_by})
  end

  describe "the :initial row" do
    test "is written on create with a nil from_state and triggered_by: :initial" do
      incident = report!()

      assert [row] = Incident.history(incident)
      assert row.from_state == nil
      assert row.to_state == :triaging
      assert row.transition_name == :report
      assert row.triggered_by == :initial
    end
  end

  describe "automatic steps" do
    test "success writes triggered_by: :automatic" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :classify_severity)

      assert [_initial, automatic] = Incident.history(incident)
      assert automatic.from_state == :triaging
      assert automatic.to_state == :investigating
      assert automatic.triggered_by == :automatic
    end

    test "the on_error path writes triggered_by: :error_path" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :__on_error_triaging)

      assert [_initial, error_row] = Incident.history(incident)
      assert error_row.from_state == :triaging
      assert error_row.to_state == :triage_failed
      assert error_row.triggered_by == :error_path
    end
  end

  describe "manual transitions" do
    test "write triggered_by: :manual and can capture an actor" do
      incident = report!()
      responder = responder!()

      {:ok, incident} = Ash.update(incident, action: :classify_severity)
      {:ok, incident} = Ash.update(incident, action: :escalate, actor: responder)

      assert names(Incident.history(incident)) == [
               {nil, :triaging, :report, :initial},
               {:triaging, :investigating, :classify_severity, :automatic},
               {:investigating, :escalated, :escalate, :manual}
             ]

      assert [_initial, _automatic, escalate_row] = Incident.history(incident)
      assert escalate_row.responder_id == responder.id
    end

    test "leaves the actor nil when no actor is given" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :classify_severity)
      {:ok, incident} = Ash.update(incident, action: :escalate)

      assert [_initial, _automatic, escalate_row] = Incident.history(incident)
      assert escalate_row.responder_id == nil
    end
  end

  describe "timeouts" do
    test "a transitioning timeout writes triggered_by: :timeout" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :classify_severity)
      {:ok, incident} = Ash.update(incident, action: :__timeout_investigating_auto_escalate)

      assert [_initial, _automatic, escalation] = Incident.history(incident)
      assert escalation.from_state == :investigating
      assert escalation.to_state == :escalated
      assert escalation.triggered_by == :timeout
    end

    test "an every writes a from_state == to_state row" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :classify_severity)
      {:ok, incident} = Ash.update(incident, action: :send_status_update)

      assert [_initial, _automatic, reminder] = Incident.history(incident)
      assert reminder.from_state == :investigating
      assert reminder.to_state == :investigating
      assert reminder.triggered_by == :timeout
    end

    test "firing an every three times writes three from_state == to_state rows" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :classify_severity)

      incident =
        Enum.reduce(1..3, incident, fn _, incident ->
          {:ok, incident} = Ash.update(incident, action: :send_status_update)
          incident
        end)

      fired_three_times =
        incident
        |> Incident.history()
        |> Enum.filter(&(&1.from_state == :investigating and &1.to_state == :investigating))

      assert length(fired_three_times) == 3
      assert incident.status_updates_sent == 3
    end
  end

  describe "history/1" do
    test "returns rows ordered by occurred_at ascending" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :classify_severity)
      {:ok, incident} = Ash.update(incident, action: :escalate)

      occurred_ats = incident |> Incident.history() |> Enum.map(& &1.occurred_at)
      assert occurred_ats == Enum.sort(occurred_ats, DateTime)
    end
  end

  describe "state_at/2" do
    test "returns nil for a time before the earliest logged row" do
      incident = report!()
      before_creation = DateTime.add(DateTime.utc_now(), -1, :day)

      assert Incident.state_at(incident, before_creation) == nil
    end

    test "returns the state active between two logged rows" do
      incident = report!()
      [initial_row] = Incident.history(incident)

      {:ok, incident} = Ash.update(incident, action: :classify_severity)
      [_initial, automatic_row] = Incident.history(incident)

      {:ok, incident} = Ash.update(incident, action: :escalate)

      assert Incident.state_at(incident, initial_row.occurred_at) == :triaging
      assert Incident.state_at(incident, automatic_row.occurred_at) == :investigating

      between =
        DateTime.add(automatic_row.occurred_at, 1, :microsecond)

      assert Incident.state_at(incident, between) == :investigating
    end

    test "returns the current state for a time at or after the last logged row" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :classify_severity)
      {:ok, incident} = Ash.update(incident, action: :escalate)

      after_everything = DateTime.add(DateTime.utc_now(), 1, :day)

      assert Incident.state_at(incident, after_everything) == :escalated
    end
  end

  describe "state_entered_at" do
    test "an every firing leaves it where the step entry set it" do
      incident = report!()
      {:ok, incident} = Ash.update(incident, action: :classify_severity)
      entered_investigating_at = incident.state_entered_at

      {:ok, incident} = Ash.update(incident, action: :send_status_update)

      assert incident.state_entered_at == entered_investigating_at
    end
  end
end
