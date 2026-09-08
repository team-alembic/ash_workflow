defmodule WorkflowTimelineWeb.UndoLiveTest do
  use WorkflowTimelineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WorkflowTimeline.IncidentResponse
  alias WorkflowTimeline.IncidentResponse.UndoableIncident

  setup do
    Application.put_env(:workflow_timeline, :fast_tests, true)
    on_exit(fn -> Application.put_env(:workflow_timeline, :fast_tests, false) end)
    :ok
  end

  defp investigating_incident!(title) do
    {:ok, incident} = IncidentResponse.report_undoable(title, "test incident")
    Ash.update!(incident, action: :classify_severity)
  end

  describe "the page" do
    test "renders an incident and offers its available transitions", %{conn: conn} do
      investigating_incident!("Queue backlog")

      {:ok, _live, html} = live(conn, ~p"/undo")

      assert html =~ "Queue backlog"
      assert html =~ "escalate"
      assert html =~ "resolve"
    end

    test "links back to the timeline", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/undo")

      assert html =~ "back to the timeline"
    end
  end

  describe "undoing" do
    test "rewinds the incident and offers the undo target up front", %{conn: conn} do
      incident = investigating_incident!("Cache storm")

      {:ok, live, _html} = live(conn, ~p"/undo")

      html =
        live
        |> element("button[phx-value-action='escalate'][phx-value-id='#{incident.id}']")
        |> render_click()

      assert html =~ "undo → Investigating"

      html = live |> element("button[phx-click='undo']") |> render_click()

      assert Ash.get!(UndoableIncident, incident.id).state == :investigating
      assert html =~ "Investigating"
    end

    test "leaves the reversed row in the log, struck through", %{conn: conn} do
      incident = investigating_incident!("Replica lag")

      {:ok, live, _html} = live(conn, ~p"/undo")

      live
      |> element("button[phx-value-action='escalate'][phx-value-id='#{incident.id}']")
      |> render_click()

      html = live |> element("button[phx-click='undo']") |> render_click()

      # Four rows: initial, classify_severity, escalate, and the undo of it.
      assert html =~ "line-through"
      assert html =~ "↩ row 3"

      incident = Ash.get!(UndoableIncident, incident.id)
      assert length(UndoableIncident.history(incident)) == 4
      assert length(UndoableIncident.history(incident, effective: true)) == 3
    end

    test "refuses once the automatic step is the most recent change", %{conn: conn} do
      investigating_incident!("Auth failures")

      {:ok, _live, html} = live(conn, ~p"/undo")

      assert html =~ "nothing to undo"
    end
  end

  describe "the effective toggle" do
    test "switches which reading the band is drawn from", %{conn: conn} do
      incident = investigating_incident!("Webhook delays")

      {:ok, live, _html} = live(conn, ~p"/undo")

      live
      |> element("button[phx-value-action='escalate'][phx-value-id='#{incident.id}']")
      |> render_click()

      live |> element("button[phx-click='undo']") |> render_click()

      html = render(live)
      assert html =~ "Showing: what happened"
      assert html =~ "bg-red-600"

      html = live |> element("button[phx-click='toggle_effective']") |> render_click()
      assert html =~ "Showing: corrected history"
      refute html =~ "bg-red-600"
    end
  end
end
