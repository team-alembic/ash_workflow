defmodule AshWorkflowDemoWeb.ExposureTest do
  @moduledoc """
  What the tunnel is allowed to reach.

  `cloudflared` publishes the whole app, so every one of these is reachable
  from the room unless something stops it.
  """

  use AshWorkflowDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate

  setup do
    Application.put_env(:ash_workflow_demo, :fast_tests, true)
    on_exit(fn -> Application.put_env(:ash_workflow_demo, :fast_tests, false) end)
    :ok
  end

  defp from_tunnel(conn), do: %{conn | host: "chosen-nickel-brief.trycloudflare.com"}

  defp start_candidate(name) do
    {:ok, candidate} = ATS.start(name, "pitch", "https://example.com/a.svg")
    candidate
  end

  defp seed_background_check(name) do
    Enum.find_value(1..100, fn _ ->
      candidate =
        name
        |> start_candidate()
        |> ready_for_hr_decision()
        |> then(fn c ->
          run_workflow_triggers(Candidate)
          reload(c)
        end)

      if candidate.state == :background_check, do: candidate
    end) || flunk("never reached :background_check")
  end

  describe "the operator pages" do
    test "the kanban serves locally", %{conn: conn} do
      assert html_response(get(conn, "/"), 200) =~ "Kanban"
    end

    test "the kanban 404s through the tunnel", %{conn: conn} do
      assert conn |> from_tunnel() |> get("/") |> html_response(404)
    end

    test "the timeline 404s through the tunnel", %{conn: conn} do
      assert conn |> from_tunnel() |> get("/timeline") |> html_response(404)
    end

    test "the retired redirects 404 through the tunnel too", %{conn: conn} do
      assert conn |> from_tunnel() |> get("/history") |> html_response(404)
      assert conn |> from_tunnel() |> get("/rewind") |> html_response(404)
    end

    test "LOCAL_EXTRA_HOSTS opens the board to a named second screen", %{conn: conn} do
      System.put_env("LOCAL_EXTRA_HOSTS", "macbook.local:4000")
      on_exit(fn -> System.delete_env("LOCAL_EXTRA_HOSTS") end)

      assert %{conn | host: "macbook.local"} |> get("/") |> html_response(200)
    end
  end

  describe "the audience pages" do
    test "applying still works through the tunnel", %{conn: conn} do
      assert conn |> from_tunnel() |> get("/apply") |> html_response(200)
    end

    test "the bureau portal still works through the tunnel", %{conn: conn} do
      assert conn |> from_tunnel() |> get("/dbs") |> html_response(200)
    end

    test "a candidate's own page still works through the tunnel", %{conn: conn} do
      candidate = start_candidate("Audience")

      assert conn |> from_tunnel() |> get("/c/#{candidate.id}") |> html_response(200)
    end
  end

  describe "the bureau webhook" do
    setup do
      System.delete_env("BUREAU_TOKEN")
      on_exit(fn -> System.delete_env("BUREAU_TOKEN") end)
      :ok
    end

    test "an untokened caller cannot put its own text on the projector", %{conn: conn} do
      candidate = seed_background_check("Targeted")

      body =
        conn
        |> post("/webhooks/dbs", %{
          "reference" => candidate.dbs_reference,
          "result" => "flagged",
          "offence" => "SOMETHING ABUSIVE ABOUT A REAL PERSON"
        })
        |> json_response(200)

      assert body["status"] == "accepted"
      assert body["offence"] =~ "ignored"

      offence = reload(candidate).dbs_offence
      refute offence == "SOMETHING ABUSIVE ABOUT A REAL PERSON"
      assert offence in AshWorkflowDemo.ATS.Candidate.DbsOffences.all()
    end

    test "a wrong token is refused the same way", %{conn: conn} do
      System.put_env("BUREAU_TOKEN", "the-real-token")
      candidate = seed_background_check("Wrong Token")

      conn
      |> put_req_header("x-bureau-token", "not-the-token")
      |> post("/webhooks/dbs", %{
        "reference" => candidate.dbs_reference,
        "result" => "flagged",
        "offence" => "nope"
      })
      |> json_response(200)

      refute reload(candidate).dbs_offence == "nope"
    end

    test "the right token sets the offence", %{conn: conn} do
      System.put_env("BUREAU_TOKEN", "the-real-token")
      candidate = seed_background_check("Right Token")

      conn
      |> put_req_header("x-bureau-token", "the-real-token")
      |> post("/webhooks/dbs", %{
        "reference" => candidate.dbs_reference,
        "result" => "flagged",
        "offence" => "Renamed main to master, twice."
      })
      |> json_response(200)

      assert reload(candidate).dbs_offence == "Renamed main to master, twice."
    end

    test "a tokened offence is still trimmed to what fits on a slide", %{conn: conn} do
      System.put_env("BUREAU_TOKEN", "the-real-token")
      candidate = seed_background_check("Long Offence")

      conn
      |> put_req_header("x-bureau-token", "the-real-token")
      |> post("/webhooks/dbs", %{
        "reference" => candidate.dbs_reference,
        "result" => "flagged",
        "offence" => String.duplicate("a", 500)
      })
      |> json_response(200)

      assert String.length(reload(candidate).dbs_offence) == 120
    end

    test "returning a clear result needs no token", %{conn: conn} do
      candidate = seed_background_check("Cleared")

      assert conn
             |> post("/webhooks/dbs", %{
               "reference" => candidate.dbs_reference,
               "result" => "clear"
             })
             |> json_response(200)
             |> Map.get("status") == "accepted"
    end
  end

  describe "what a candidate can type" do
    test "an over-long name is refused rather than projected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/apply")

      html =
        render_submit(view, "submit", %{
          "candidate" => %{"name" => String.duplicate("A", 300), "pitch" => "hello"}
        })

      assert html =~ "60 characters or fewer"
      assert %{results: []} = ATS.list_candidates!(authorize?: false)
    end

    test "an over-long pitch is refused rather than projected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/apply")

      html =
        render_submit(view, "submit", %{
          "candidate" => %{"name" => "Fine", "pitch" => String.duplicate("b", 5000)}
        })

      assert html =~ "200 characters or fewer"
      assert %{results: []} = ATS.list_candidates!(authorize?: false)
    end

    test "markup in a name is escaped everywhere it is shown", %{conn: conn} do
      {:ok, candidate} =
        ATS.start("<script>alert(1)</script>", "pitch", "https://example.com/a.svg")

      for path <- ["/", "/timeline", "/c/#{candidate.id}"] do
        html = conn |> get(path) |> html_response(200)
        refute html =~ "<script>alert(1)</script>"
        assert html =~ "&lt;script&gt;"
      end
    end
  end
end
