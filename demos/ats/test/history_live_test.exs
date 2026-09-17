defmodule AshWorkflowDemoWeb.HistoryLiveTest do
  use AshWorkflowDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate
  alias AshWorkflowDemo.ATS.DbsBureau

  setup do
    Application.put_env(:ash_workflow_demo, :fast_tests, true)
    on_exit(fn -> Application.put_env(:ash_workflow_demo, :fast_tests, false) end)
    :ok
  end

  defp start_candidate(name) do
    {:ok, candidate} = ATS.start(name, "pitch", "https://example.com/a.svg")
    candidate
  end

  defp drive_hr_decision(candidate) do
    candidate
    |> ready_for_hr_decision()
    |> then(fn c ->
      run_workflow_triggers(Candidate)
      reload(c)
    end)
  end

  defp drive_lead_decision(candidate) do
    candidate
    |> ready_for_lead_decision()
    |> then(fn c ->
      run_workflow_triggers(Candidate)
      reload(c)
    end)
  end

  defp until_state(state, attempt, tries \\ 100) do
    Enum.find_value(1..tries, fn _ ->
      candidate = attempt.()
      if candidate.state == state, do: candidate
    end) || flunk("never reached #{state} in #{tries} tries")
  end

  defp seed_background_check(name) do
    until_state(:background_check, fn -> name |> start_candidate() |> drive_hr_decision() end)
  end

  defp seed_final_approval(name) do
    until_state(:final_approval, fn ->
      candidate = seed_background_check(name)
      {:ok, cleared} = DbsBureau.return_result(candidate.dbs_reference, :clear)
      drive_lead_decision(cleared)
    end)
  end

  test "renders a candidate's log with when, from -> to, transition and triggered by", %{
    conn: conn
  } do
    start_candidate("Alice")

    {:ok, _view, html} = live(conn, "/history")

    assert html =~ "Candidate history"
    assert html =~ "Alice"
    assert html =~ "HR screen"
    assert html =~ "submitted"
  end

  test "links to the kanban and the rewind page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/history")

    assert html =~ "the kanban"
    assert html =~ "the playhead"
  end

  test "a candidate whose last change was automatic offers nothing to undo", %{conn: conn} do
    seed_background_check("Freshly Screened")

    {:ok, _view, html} = live(conn, "/history")

    assert html =~ "nothing to undo"
  end

  describe "undo" do
    test "undoing :offer rewinds the candidate and leaves the reversed row struck through", %{
      conn: conn
    } do
      winner = seed_final_approval("Winner")
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      {:ok, live, _html} = live(conn, "/history")

      html =
        live |> element("button[phx-click='undo'][phx-value-id='#{hired.id}']") |> render_click()

      assert reload(hired).state == :final_approval
      assert html =~ "El Jefe"
      assert html =~ "line-through"
      assert html =~ "↩ row"
    end

    test "undoing twice is a redo — it lands back on the state undone away from", %{conn: conn} do
      winner = seed_final_approval("RedoMe")
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      {:ok, live, _html} = live(conn, "/history")

      live |> element("button[phx-click='undo'][phx-value-id='#{hired.id}']") |> render_click()
      live |> element("button[phx-click='undo'][phx-value-id='#{hired.id}']") |> render_click()

      assert reload(hired).state == :hired
    end
  end

  describe "the effective toggle" do
    test "switches which reading the band is drawn from", %{conn: conn} do
      winner = seed_final_approval("ToggleMe")
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      {:ok, live, _html} = live(conn, "/history")

      live |> element("button[phx-click='undo'][phx-value-id='#{hired.id}']") |> render_click()

      html = render(live)
      assert html =~ "Showing: what happened"
      assert html =~ "bg-emerald-600"

      html = live |> element("button[phx-click='toggle_effective']") |> render_click()
      assert html =~ "Showing: corrected history"
    end
  end
end
