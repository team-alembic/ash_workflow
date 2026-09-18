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

  ## The `offence` parameter

  This endpoint is unauthenticated, the tunnel publishes it, and every live
  `dbs_reference` is printed on `/dbs` and on the kanban cards. A free-text
  `offence` would therefore let anyone in the room write whatever they like
  onto the projector, under the name of a real person standing in it.

  So `offence` is honoured only when the request carries `x-bureau-token`
  matching `BUREAU_TOKEN`. Without it the bureau picks from
  `AshWorkflowDemo.ATS.Candidate.DbsOffences` as it always did, and the
  response says the text was ignored rather than failing the call. With
  `BUREAU_TOKEN` unset, no custom text is ever accepted.

      BUREAU_TOKEN=$(openssl rand -hex 16) mix phx.server
  """

  use AshWorkflowDemoWeb, :controller

  alias AshWorkflowDemo.ATS.DbsBureau

  @offence_max_chars 120

  def create(conn, %{"reference" => reference, "result" => result})
      when result in ["clear", "flagged"] do
    {offence, ignored?} = requested_offence(conn)

    case DbsBureau.return_result(reference, String.to_existing_atom(result), offence) do
      {:ok, candidate} ->
        json(
          conn,
          %{status: "accepted", candidate_id: candidate.id, state: candidate.state}
          |> maybe_note_ignored(ignored?)
        )

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

  # Returns the offence to use and whether one was asked for but refused, so
  # the caller learns their text was dropped instead of wondering why the
  # projector says something else.
  defp requested_offence(conn) do
    case conn.params["offence"] do
      text when is_binary(text) and text != "" ->
        if authorised?(conn), do: {clamp(text), false}, else: {nil, true}

      _ ->
        {nil, false}
    end
  end

  defp authorised?(conn) do
    with [presented] <- get_req_header(conn, "x-bureau-token"),
         expected when is_binary(expected) and expected != "" <- System.get_env("BUREAU_TOKEN") do
      Plug.Crypto.secure_compare(presented, expected)
    else
      _ -> false
    end
  end

  # A projector has a finite amount of room, and a control character in the
  # middle of the offence helps nobody read it.
  defp clamp(text) do
    text
    |> String.replace(~r/[[:cntrl:]]/u, " ")
    |> String.trim()
    |> String.slice(0, @offence_max_chars)
  end

  defp maybe_note_ignored(body, false), do: body

  defp maybe_note_ignored(body, true),
    do: Map.put(body, :offence, "ignored — send x-bureau-token to set your own")
end
