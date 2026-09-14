defmodule AshWorkflowDemoWeb.DbsWebhookController do
  @moduledoc """
  The bureau's HTTP entry point.

      curl -X POST $TUNNEL_URL/webhooks/dbs \\
        -H 'content-type: application/json' \\
        -d '{"reference": "DBS-1A2B3C", "result": "flagged"}'

  The `:already_returned` branch is the whole reason this is longer than one
  line. A webhook gets redelivered, the second delivery finds the candidate
  past `:background_check`, and answering 409 would make the bureau retry
  forever. Deciding that per endpoint by hand is what a declarative wait state
  with event de-duplication would take over.
  """

  use AshWorkflowDemoWeb, :controller

  alias AshWorkflowDemo.ATS.DbsBureau

  def create(conn, %{"reference" => reference, "result" => result})
      when result in ["clear", "flagged"] do
    offence = conn.params["offence"]

    case DbsBureau.return_result(reference, String.to_existing_atom(result), offence) do
      {:ok, candidate} ->
        json(conn, %{status: "accepted", candidate_id: candidate.id, state: candidate.state})

      :already_returned ->
        json(conn, %{status: "duplicate"})

      :unknown_reference ->
        conn |> put_status(:not_found) |> json(%{error: "unknown reference"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: ~s(expected {"reference": "DBS-…", "result": "clear" | "flagged"})})
  end
end
