defmodule AshWorkflowDemoWeb.TimelineLiveTest do
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

  # Backdates the candidate's log rows so its band spans real wall-clock time,
  # the way a candidate applying minutes ago would.
  defp backdated_candidate!(name, minutes_ago) do
    candidate = seed_background_check(name)

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

  defp expand(view, candidate) do
    view
    |> element("button[phx-click='toggle_expand'][phx-value-id='#{candidate.id}']")
    |> render_click()
  end

  describe "the playhead" do
    test "renders a band per candidate with a slider", %{conn: conn} do
      backdated_candidate!("Alice", 5)
      backdated_candidate!("Bob", 20)

      {:ok, _view, html} = live(conn, "/timeline")

      assert html =~ "Timeline"
      assert html =~ "Alice"
      assert html =~ "Bob"
      assert html =~ "type=\"range\""
    end

    test "moving the slider updates the playhead and each candidate's state readout", %{
      conn: conn
    } do
      backdated_candidate!("Alice", 10)

      {:ok, view, _html} = live(conn, "/timeline")

      html_at_start = render_change(view, "slide", %{"at" => "0"})
      assert html_at_start =~ "HR screen"

      html_at_end = render_change(view, "slide", %{"at" => "1000"})
      assert html_at_end =~ "DBS check"
    end

    test "the window starts at the earliest logged row, not at page load", %{conn: conn} do
      candidate = backdated_candidate!("Earliest", 30)
      [first | _] = Candidate.history(candidate)

      {:ok, _view, html} = live(conn, "/timeline")

      assert html =~ Calendar.strftime(first.occurred_at, "%H:%M:%S")
    end

    test "the window ends a minute past the last logged row, not at now", %{conn: conn} do
      # Backdated by an hour, so a window running to `now` would show a
      # wall-clock end time rather than one anchored to the log.
      candidate = backdated_candidate!("Bounded", 60)
      last = candidate |> Candidate.history() |> List.last()
      expected_end = DateTime.add(last.occurred_at, 60, :second)

      {:ok, _view, html} = live(conn, "/timeline")

      assert html =~ Calendar.strftime(expected_end, "%H:%M:%S")
      refute html =~ Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    end

    test "a new event extends the window to a minute past itself", %{conn: conn} do
      backdated_candidate!("Settled", 60)

      {:ok, view, _html} = live(conn, "/timeline")

      latecomer = start_candidate("Latecomer")
      [row] = Candidate.history(latecomer)

      assert render(view) =~
               Calendar.strftime(DateTime.add(row.occurred_at, 60, :second), "%H:%M:%S")
    end

    test "a candidate created after mount appears on the next candidate_changed broadcast", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/timeline")
      refute html =~ "Latecomer"

      start_candidate("Latecomer")
      render(view)

      assert render(view) =~ "Latecomer"
    end
  end

  describe "unfolding a candidate" do
    test "the log is folded away until the candidate is clicked", %{conn: conn} do
      candidate = seed_background_check("Foldy")

      {:ok, view, html} = live(conn, "/timeline")
      refute html =~ "triggered by"

      html = expand(view, candidate)

      assert html =~ "triggered by"
      assert html =~ "record_hr_screen"
      assert html =~ "submitted"
    end

    test "clicking a second time folds it back away", %{conn: conn} do
      candidate = seed_background_check("Foldy")

      {:ok, view, _html} = live(conn, "/timeline")

      expand(view, candidate)
      html = expand(view, candidate)

      refute html =~ "triggered by"
    end

    test "each candidate's name links to its own page", %{conn: conn} do
      candidate = seed_background_check("Clickable")

      {:ok, _view, html} = live(conn, "/timeline")

      assert html =~ ~s(href="/c/#{candidate.id}")
    end
  end

  describe "scrubbing an unfolded log" do
    test "rows after the playhead drop off the list and come back", %{conn: conn} do
      candidate = backdated_candidate!("Scrubby", 20)

      {:ok, view, _html} = live(conn, "/timeline")
      expand(view, candidate)

      at_end = render(view)
      assert at_end =~ "record_hr_screen"
      refute at_end =~ "event(s) hidden"

      at_start = render_change(view, "slide", %{"at" => "0"})
      refute at_start =~ "record_hr_screen"

      hidden = length(Candidate.history(candidate)) - 1
      assert at_start =~ "#{hidden} later"

      back_at_end = render_change(view, "slide", %{"at" => "1000"})
      assert back_at_end =~ "record_hr_screen"
      refute back_at_end =~ "event(s) hidden"
    end

    test "row numbers count from the first row, not from the first shown row", %{conn: conn} do
      winner = seed_final_approval("Numbered")
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      {:ok, view, _html} = live(conn, "/timeline")
      expand(view, hired)
      view |> element("button[phx-click='undo'][phx-value-id='#{hired.id}']") |> render_click()

      # The undo row points at the :offer row by its absolute position, which
      # is only right if the numbering ignores which rows the playhead hides.
      offer_index =
        hired
        |> reload()
        |> Candidate.history()
        |> Enum.find_index(&(&1.to_state == :hired))
        |> Kernel.+(1)

      assert render(view) =~ "↩ row #{offer_index}"
    end
  end

  describe "undo" do
    test "undoing :offer rewinds the candidate and leaves the reversed row struck through", %{
      conn: conn
    } do
      winner = seed_final_approval("Winner")
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      {:ok, view, _html} = live(conn, "/timeline")
      expand(view, hired)

      html =
        view |> element("button[phx-click='undo'][phx-value-id='#{hired.id}']") |> render_click()

      assert reload(hired).state == :final_approval
      assert html =~ "El Jefe"
      assert html =~ "line-through"
      assert html =~ "↩ row"
    end

    test "undoing twice is a redo — it lands back on the state undone away from", %{conn: conn} do
      winner = seed_final_approval("RedoMe")
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      {:ok, view, _html} = live(conn, "/timeline")

      view |> element("button[phx-click='undo'][phx-value-id='#{hired.id}']") |> render_click()
      view |> element("button[phx-click='undo'][phx-value-id='#{hired.id}']") |> render_click()

      assert reload(hired).state == :hired
    end

    test "a candidate whose last change was automatic offers nothing to undo", %{conn: conn} do
      seed_background_check("Freshly Screened")

      {:ok, _view, html} = live(conn, "/timeline")

      assert html =~ "nothing to undo"
    end
  end

  describe "the retired routes" do
    test "/history redirects to /timeline", %{conn: conn} do
      assert redirected_to(get(conn, "/history")) == "/timeline"
    end

    test "/rewind redirects to /timeline", %{conn: conn} do
      assert redirected_to(get(conn, "/rewind")) == "/timeline"
    end
  end
end
