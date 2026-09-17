defmodule AshWorkflowDemoWeb.RewindLiveTest do
  use AshWorkflowDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate

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

  defp until_state(state, attempt, tries \\ 100) do
    Enum.find_value(1..tries, fn _ ->
      candidate = attempt.()
      if candidate.state == state, do: candidate
    end) || flunk("never reached #{state} in #{tries} tries")
  end

  # Backdates the candidate's log rows so its band spans real wall-clock time,
  # the way a candidate applying minutes ago would.
  defp backdated_candidate!(name, minutes_ago, reach \\ :background_check) do
    candidate =
      until_state(reach, fn -> name |> start_candidate() |> drive_hr_decision() end)

    now = DateTime.utc_now()
    started = DateTime.add(now, -minutes_ago * 60, :second)

    history = Candidate.history(candidate)
    step = div(minutes_ago * 60, max(length(history) - 1, 1))

    history
    |> Enum.with_index()
    |> Enum.each(fn {row, index} ->
      occurred_at = DateTime.add(started, index * step, :second)
      set_datetime(row, :occurred_at, occurred_at)
    end)

    reload(candidate)
  end

  test "renders a band per candidate with a slider", %{conn: conn} do
    backdated_candidate!("Alice", 5)
    backdated_candidate!("Bob", 20)

    {:ok, _view, html} = live(conn, "/rewind")

    assert html =~ "Rewind"
    assert html =~ "Alice"
    assert html =~ "Bob"
    assert html =~ "type=\"range\""
  end

  test "moving the slider updates the playhead and each candidate's state readout", %{
    conn: conn
  } do
    backdated_candidate!("Alice", 10)

    {:ok, view, _html} = live(conn, "/rewind")

    html_at_start = render_change(view, "slide", %{"at" => "0"})
    assert html_at_start =~ "HR screen"

    html_at_end = render_change(view, "slide", %{"at" => "1000"})
    assert html_at_end =~ "DBS check"
  end

  test "links to the kanban and the transition log", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/rewind")

    assert html =~ "the kanban"
    assert html =~ "the transition log"
  end

  test "a candidate created after mount appears on the next candidate_changed broadcast", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/rewind")
    refute html =~ "Latecomer"

    start_candidate("Latecomer")
    render(view)

    assert render(view) =~ "Latecomer"
  end
end
