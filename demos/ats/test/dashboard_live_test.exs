defmodule AshWorkflowDemoWeb.DashboardLiveTest do
  use AshWorkflowDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshWorkflowDemo.ATS

  setup do
    Application.put_env(:ash_workflow_demo, :fast_tests, true)
    on_exit(fn -> Application.put_env(:ash_workflow_demo, :fast_tests, false) end)
    :ok
  end

  defp seed_reviewable(name) do
    {:ok, candidate} = ATS.start(name, "pitch", "https://example.com/a.svg")

    candidate = ready_to_verify(candidate)
    run_workflow_triggers(AshWorkflowDemo.ATS.Candidate)

    reload(candidate)
  end

  test "dashboard renders with El Jefe branding and column counts", %{conn: conn} do
    seed_reviewable("Alice")
    seed_reviewable("Bob")

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "El Jefe"
    assert html =~ "Kanban"
    assert html =~ "Insert Random Candidate"
    assert html =~ "Reset the Req"
    assert html =~ "Alice"
    assert html =~ "Bob"
  end

  test "clicking hire on one card cascades all other :review candidates to :position_filled", %{
    conn: conn
  } do
    c1 = seed_reviewable("Winner")
    c2 = seed_reviewable("Loser1")
    c3 = seed_reviewable("Loser2")

    {:ok, view, _html} = live(conn, "/")

    html = render_click(view, "hire", %{"id" => c1.id})

    assert html =~ "Winner"
    # Winner should be in Hired column, losers in Position filled
    {:ok, c1_after} = ATS.get_candidate(c1.id)
    {:ok, c2_after} = ATS.get_candidate(c2.id)
    {:ok, c3_after} = ATS.get_candidate(c3.id)

    assert c1_after.state == :hired
    assert c2_after.state == :position_filled
    assert c3_after.state == :position_filled
  end

  test "clicking reject transitions one candidate without cascading", %{conn: conn} do
    c1 = seed_reviewable("Rejected")
    c2 = seed_reviewable("Untouched")

    {:ok, view, _html} = live(conn, "/")
    _html = render_click(view, "reject", %{"id" => c1.id})

    {:ok, c1_after} = ATS.get_candidate(c1.id)
    {:ok, c2_after} = ATS.get_candidate(c2.id)

    assert c1_after.state == :rejected
    assert c2_after.state == :review
  end

  test "insert_random adds a candidate in :submitted", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    _html = render_click(view, "insert_random")

    %{results: candidates} = ATS.list_candidates!(authorize?: false)
    assert length(candidates) == 1
    [c] = candidates
    assert c.state == :submitted
  end

  test "reset transitions :review candidates to :position_filled", %{conn: conn} do
    c = seed_reviewable("ToReset")

    {:ok, view, _html} = live(conn, "/")
    _html = render_click(view, "reset")

    {:ok, c_after} = ATS.get_candidate(c.id)
    assert c_after.state == :position_filled
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
    c = seed_reviewable("ModalSubject")

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "open_card", %{"id" => c.id})

    assert html =~ "ModalSubject"
    assert html =~ "Verify score"
    # Escape closes it
    _ = render_keydown(view, "close_card", %{"key" => "Escape"})
    html = render(view)
    refute html =~ "Verify score"
  end

  test "hiring from inside the modal still cascades", %{conn: conn} do
    winner = seed_reviewable("ModalWinner")
    loser = seed_reviewable("ModalLoser")

    {:ok, view, _html} = live(conn, "/")
    _ = render_click(view, "open_card", %{"id" => winner.id})
    _ = render_click(view, "hire", %{"id" => winner.id})

    {:ok, w} = ATS.get_candidate(winner.id)
    {:ok, l} = ATS.get_candidate(loser.id)
    assert w.state == :hired
    assert l.state == :position_filled
  end
end
