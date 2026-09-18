defmodule AshWorkflowDemoWeb.DashboardLiveTest do
  use AshWorkflowDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshWorkflowDemo.ATS
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
      run_workflow_triggers(AshWorkflowDemo.ATS.Candidate)
      reload(c)
    end)
  end

  defp drive_lead_decision(candidate) do
    candidate
    |> ready_for_lead_decision()
    |> then(fn c ->
      run_workflow_triggers(AshWorkflowDemo.ATS.Candidate)
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

  defp seed_lead_interview(name) do
    candidate = seed_background_check(name)
    {:ok, cleared} = DbsBureau.return_result(candidate.dbs_reference, :clear)
    cleared
  end

  # Offence copy can contain quotes, which HEEx escapes on render.
  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp seed_final_approval(name) do
    until_state(:final_approval, fn ->
      seed_lead_interview(name) |> drive_lead_decision()
    end)
  end

  test "dashboard renders with El Jefe branding and column counts", %{conn: conn} do
    start_candidate("Alice")
    start_candidate("Bob")

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "El Jefe"
    assert html =~ "Kanban"
    assert html =~ "Insert Random Candidate"
    assert html =~ "Reset the Req"
    assert html =~ "Alice"
    assert html =~ "Bob"
  end

  test "clicking offer cascades every other in-flight candidate to :rejected", %{conn: conn} do
    winner = seed_final_approval("Winner")
    on_hr_screen = start_candidate("OnHrScreen")
    on_background_check = seed_background_check("OnBackgroundCheck")
    on_lead_interview = seed_lead_interview("OnLeadInterview")

    {:ok, view, _html} = live(conn, "/")

    html = render_click(view, "offer", %{"id" => winner.id})

    assert html =~ "Winner"

    {:ok, winner_after} = ATS.get_candidate(winner.id)
    assert winner_after.state == :hired
    assert reload(on_hr_screen).state == :rejected
    assert reload(on_background_check).state == :rejected
    assert reload(on_lead_interview).state == :rejected
  end

  test "clicking veto rejects one candidate without cascading", %{conn: conn} do
    vetoed = seed_final_approval("Vetoed")
    bystander = start_candidate("Untouched")

    {:ok, view, _html} = live(conn, "/")
    _html = render_click(view, "veto", %{"id" => vetoed.id})

    {:ok, vetoed_after} = ATS.get_candidate(vetoed.id)
    assert vetoed_after.state == :rejected
    assert reload(bystander).state == :hr_screen
  end

  test "insert_random adds a candidate on :hr_screen", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    _html = render_click(view, "insert_random")

    %{results: candidates} = ATS.list_candidates!(authorize?: false)
    assert length(candidates) == 1
    [c] = candidates
    assert c.state == :hr_screen
  end

  test "reset sweeps every in-flight candidate to :rejected", %{conn: conn} do
    on_hr_screen = start_candidate("OnHrScreen")
    on_background_check = seed_background_check("OnBackgroundCheck")
    on_lead_interview = seed_lead_interview("OnLeadInterview")
    on_final_approval = seed_final_approval("OnFinalApproval")

    {:ok, view, _html} = live(conn, "/")
    _html = render_click(view, "reset")

    assert reload(on_hr_screen).state == :rejected
    assert reload(on_background_check).state == :rejected
    assert reload(on_lead_interview).state == :rejected
    assert reload(on_final_approval).state == :rejected
  end

  test "dashboard renders QR code block when tunnel_url is set", %{conn: conn} do
    AshWorkflowDemo.TunnelUrl.set("https://example.com")
    on_exit(fn -> Agent.update(AshWorkflowDemo.TunnelUrl, fn _ -> nil end) end)

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "https://example.com"
    # QR renders as SVG
    assert html =~ "<svg"
  end

  test "dashboard renders tunnel-paste form when tunnel_url is nil", %{conn: conn} do
    Agent.update(AshWorkflowDemo.TunnelUrl, fn _ -> nil end)

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Paste tunnel URL"
  end

  test "clicking a card opens a modal with its detail", %{conn: conn} do
    c = seed_background_check("ModalSubject")

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "open_card", %{"id" => c.id})

    assert html =~ "ModalSubject"
    assert html =~ "Janine&#39;s score"
    # Escape closes it
    _ = render_keydown(view, "close_card", %{"key" => "Escape"})
    html = render(view)
    refute html =~ "Janine&#39;s score"
  end

  test "offering from inside the modal still cascades", %{conn: conn} do
    winner = seed_final_approval("ModalWinner")
    loser = start_candidate("ModalLoser")

    {:ok, view, _html} = live(conn, "/")
    _ = render_click(view, "open_card", %{"id" => winner.id})
    _ = render_click(view, "offer", %{"id" => winner.id})

    {:ok, w} = ATS.get_candidate(winner.id)
    {:ok, l} = ATS.get_candidate(loser.id)
    assert w.state == :hired
    assert l.state == :rejected
  end

  test "a dbs_offence banner is impossible to miss on the card and stays visible when hired", %{
    conn: conn
  } do
    winner =
      until_state(:final_approval, fn ->
        candidate = seed_background_check("Flagged")
        {:ok, flagged} = DbsBureau.return_result(candidate.dbs_reference, :flagged)
        drive_lead_decision(flagged)
      end)

    {:ok, view, html} = live(conn, "/")
    assert html =~ "bg-bubble-alarm"
    assert html =~ html_escape(winner.dbs_offence)

    html = render_click(view, "offer", %{"id" => winner.id})

    assert html =~ html_escape(winner.dbs_offence)
  end

  test "maximising a column renders the character's name, bio, and its candidates", %{
    conn: conn
  } do
    on_hr_screen = start_candidate("MaximisedOne")

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "maximise", %{"state" => "hr_screen"})

    assert html =~ "Janine"
    assert html =~ "Head of People &amp; Culture"
    assert html =~ "Owns the req"
    assert html =~ on_hr_screen.name

    # Escape closes it
    _ = render_keydown(view, "close_maximised", %{"key" => "Escape"})
    html = render(view)
    refute html =~ "Owns the req"
  end

  test "maximising an empty column shows that character's empty-state line", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "maximise", %{"state" => "hired"})

    assert html =~ "Nobody hired yet."
  end

  test "the QR overlay renders the apply URL", %{conn: conn} do
    AshWorkflowDemo.TunnelUrl.set("https://example.com")
    on_exit(fn -> Agent.update(AshWorkflowDemo.TunnelUrl, fn _ -> nil end) end)

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "maximise_qr")

    assert html =~ "https://example.com/apply"

    _ = render_keydown(view, "close_maximised_qr", %{"key" => "Escape"})
    html = render(view)
    refute html =~ "close_maximised_qr"
  end

  describe "the countdowns" do
    alias AshWorkflow.Scheduler.Precise
    alias AshWorkflowDemo.ATS.Candidate
    alias AshWorkflowDemo.ATS.Candidate.Deadlines

    test "counts down HR screen from the duration the DSL declares", %{conn: conn} do
      start_candidate("Counting")

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "#{Deadlines.seconds(:janine_responds)}s left"
    end

    test "the bureau countdown reaches zero exactly when the deadline is due", %{conn: conn} do
      candidate = seed_background_check("Zero")
      aged = age_by(candidate, Deadlines.seconds(:bureau_responds), :second)

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "0s left"

      run_workflow_triggers(Candidate)
      assert reload(aged).state == :lead_interview
    end

    test "the bureau countdown still counts a second before, and the scheduler agrees", %{
      conn: conn
    } do
      candidate = seed_background_check("OneLeft")
      aged = age_by(candidate, Deadlines.seconds(:bureau_responds) - 1, :second)

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "1s left"

      assert Precise.run_due(Candidate) == 0
      assert reload(aged).state == :background_check
    end
  end
end
