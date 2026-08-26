defmodule WorkflowTimelineWeb.TimelineLiveTest do
  use WorkflowTimelineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WorkflowTimeline.IncidentResponse
  alias WorkflowTimeline.IncidentResponse.Incident

  setup do
    Application.put_env(:workflow_timeline, :fast_tests, true)
    on_exit(fn -> Application.put_env(:workflow_timeline, :fast_tests, false) end)
    :ok
  end

  defp backdated_incident!(title, hours_ago) do
    {:ok, incident} = IncidentResponse.report(title, "test incident")
    {:ok, incident} = Ash.update(incident, action: :classify_severity)
    {:ok, incident} = Ash.update(incident, action: :send_status_update)

    now = DateTime.utc_now()
    started = DateTime.add(now, -hours_ago * 3600, :second)

    history = Incident.history(incident)
    step = div(hours_ago * 3600, max(length(history) - 1, 1))

    history
    |> Enum.with_index()
    |> Enum.each(fn {row, index} ->
      occurred_at = DateTime.add(started, index * step, :second)

      row
      |> Ash.Changeset.for_update(:backdate, %{occurred_at: occurred_at})
      |> Ash.update!()
    end)

    incident
    |> Ash.Changeset.for_update(:seed_snapshot, %{
      state_entered_at: DateTime.add(started, (length(history) - 1) * step, :second)
    })
    |> Ash.update!()

    incident
  end

  test "renders a band per incident with state, timestamps, and a slider", %{conn: conn} do
    backdated_incident!("Checkout latency spike", 5)
    backdated_incident!("Elevated 5xx on API gateway", 20)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Incident timeline"
    assert html =~ "Checkout latency spike"
    assert html =~ "Elevated 5xx on API gateway"
    assert html =~ "state_entered_at"
    assert html =~ "entered_current_state_at"
    assert html =~ "type=\"range\""
  end

  test "moving the slider updates the playhead and each incident's state readout", %{conn: conn} do
    backdated_incident!("Checkout latency spike", 10)

    {:ok, view, _html} = live(conn, "/")

    html_at_start = render_change(view, "slide", %{"at" => "0"})
    assert html_at_start =~ "Triaging"

    html_at_end = render_change(view, "slide", %{"at" => "1000"})
    assert html_at_end =~ "Investigating"
    refute html_at_end =~ "Triaging</span>"
  end

  test "generate_history adds a new band", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute html =~ "state at playhead"

    html = render_click(view, "generate_history")
    assert html =~ "state at playhead"
  end
end
