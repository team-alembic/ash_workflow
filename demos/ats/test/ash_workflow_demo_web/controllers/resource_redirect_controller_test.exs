defmodule AshWorkflowDemoWeb.ResourceRedirectControllerTest do
  use AshWorkflowDemoWeb.ConnCase, async: true

  alias AshWorkflowDemoWeb.ResourceRedirectController

  defp from_tunnel(conn), do: %{conn | host: "chosen-nickel-brief.trycloudflare.com"}

  test "every slug redirects to its source", %{conn: conn} do
    for {slug, url} <- ResourceRedirectController.sources() do
      assert conn |> get(~p"/resources/#{slug}") |> redirected_to(302) == url
    end
  end

  test "the room reaches them through the tunnel", %{conn: conn} do
    conn = conn |> from_tunnel() |> get(~p"/resources/rovelli")

    assert redirected_to(conn, 302) == "https://arxiv.org/abs/0903.3832"
  end

  test "an unknown slug is a 404 rather than an open redirect", %{conn: conn} do
    conn = get(conn, ~p"/resources/https:%2F%2Fexample.com")

    assert response(conn, 404) =~ "Unknown source"
  end
end
