defmodule AshWorkflowDemoWeb.CandidateLiveTest do
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

  # Offence copy can contain quotes and backticks, which HEEx escapes on render.
  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
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

  defp seed_rejected_by_janine(name) do
    until_state(:rejected, fn -> name |> start_candidate() |> drive_hr_decision() end)
  end

  describe "the three reviewer columns" do
    test "all three are on the page from the moment a candidate applies", %{conn: conn} do
      candidate = start_candidate("Fresh")

      {:ok, _view, html} = live(conn, ~p"/c/#{candidate.id}")

      assert html =~ "Janine"
      assert html =~ "Steve"
      assert html =~ "El Jefe"
    end

    test "El Jefe's column stays on the page for a candidate Janine turned down", %{conn: conn} do
      candidate = seed_rejected_by_janine("Turned Down")

      {:ok, _view, html} = live(conn, ~p"/c/#{candidate.id}")

      assert html =~ "El Jefe"
      assert html =~ "Never reached his desk."
    end
  end

  describe "El Jefe's column" do
    test "greys out and reads 'never reached his desk' by default", %{conn: conn} do
      candidate = seed_rejected_by_janine("Never Got There")

      {:ok, _view, html} = live(conn, ~p"/c/#{candidate.id}")

      assert html =~ "Never reached his desk."
      assert html =~ "opacity-25 grayscale"
      # #4b5563 is the dim tone; neither the good nor the bad hue is used.
      assert html =~ "color: #4b5563"
    end

    test "lights up green when he makes the offer", %{conn: conn} do
      winner = seed_final_approval("Winner")
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      {:ok, _view, html} = live(conn, ~p"/c/#{hired.id}")

      assert html =~ "Offer"
      assert html =~ "He picked you."
      assert html =~ "color: #10b981"
    end

    test "lights up red when he vetoes", %{conn: conn} do
      candidate = seed_final_approval("Vetoed")
      {:ok, vetoed} = ATS.veto(candidate, %{}, authorize?: false)

      {:ok, _view, html} = live(conn, ~p"/c/#{vetoed.id}")

      assert html =~ "Veto"
      assert html =~ "He turned you down himself."
      assert html =~ "color: #f43f5e"
    end

    # :slot_taken shares the :final_approval -> :rejected edge with :veto, but
    # it is the cascade off somebody else's offer, not an answer about this
    # candidate. It stays grey.
    test "stays grey when the cascade swept the candidate off his desk", %{conn: conn} do
      winner = seed_final_approval("Winner")
      bystander = seed_final_approval("Bystander")

      {:ok, _hired} = ATS.offer(winner, %{}, authorize?: false)

      {:ok, _view, html} = live(conn, ~p"/c/#{bystander.id}")

      assert reload(bystander).state == :rejected
      assert html =~ "Too late"
      assert html =~ "Somebody else took the slot."
      assert html =~ "color: #4b5563"
      refute html =~ "He turned you down himself."
    end

    test "is muted rather than dimmed while the candidate is on his desk", %{conn: conn} do
      candidate = seed_final_approval("Waiting")

      {:ok, _view, html} = live(conn, ~p"/c/#{candidate.id}")

      assert html =~ "Deciding"
      assert html =~ "color: #9aa4b2"
      refute html =~ "opacity-25 grayscale"
    end
  end

  describe "the page itself" do
    test "fills one slide without scrolling", %{conn: conn} do
      candidate = start_candidate("Slide")

      {:ok, _view, html} = live(conn, ~p"/c/#{candidate.id}")

      assert html =~ "h-screen"
      assert html =~ "overflow-hidden"
      assert html =~ "grid-cols-3"
    end

    test "a disclosure on file is shown to the candidate", %{conn: conn} do
      candidate = seed_background_check("Flagged")
      {:ok, flagged} = DbsBureau.return_result(candidate.dbs_reference, :flagged)

      {:ok, _view, html} = live(conn, ~p"/c/#{flagged.id}")

      assert html =~ "Disclosure on file"
      assert html =~ html_escape(reload(flagged).dbs_offence)
    end

    test "it follows the candidate on the next broadcast", %{conn: conn} do
      candidate = seed_final_approval("Live")

      {:ok, view, html} = live(conn, ~p"/c/#{candidate.id}")
      assert html =~ "Deciding"

      {:ok, _hired} = ATS.offer(candidate, %{}, authorize?: false)

      assert render(view) =~ "He picked you."
    end
  end
end
