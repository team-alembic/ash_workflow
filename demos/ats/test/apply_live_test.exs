defmodule AshWorkflowDemoWeb.ApplyLiveTest do
  use AshWorkflowDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:ash_workflow_demo, :fast_tests, true)
    on_exit(fn -> Application.put_env(:ash_workflow_demo, :fast_tests, false) end)
    :ok
  end

  test "apply page renders with El Jefe branding", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/apply")
    assert html =~ "¿Y usted quién es?"
    assert html =~ "El Jefe is hiring"
    assert html =~ "Apply"
  end

  test "submitting the form creates a candidate and redirects to self-view", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/apply")

    assert {:error, {:live_redirect, %{to: path}}} =
             render_submit(view, "submit", %{
               "candidate" => %{"name" => "TestCandidate", "pitch" => "a real pitch"}
             })

    assert path =~ ~r|^/c/[0-9a-f-]+$|

    %{results: candidates} = AshWorkflowDemo.ATS.list_candidates!(authorize?: false)
    assert [c] = candidates
    assert c.name == "TestCandidate"
    assert c.pitch == "a real pitch"
    assert c.state == :verifying
    assert c.avatar_url =~ "dicebear.com"
  end

  test "empty name shows error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/apply")
    html = render_submit(view, "submit", %{"candidate" => %{"name" => "", "pitch" => "ok"}})
    assert html =~ "name cannot be empty"
  end

  test "pitch over 200 chars shows error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/apply")

    html =
      render_submit(view, "submit", %{
        "candidate" => %{"name" => "X", "pitch" => String.duplicate("a", 201)}
      })

    assert html =~ "200 characters"
  end
end
