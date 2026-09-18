defmodule WorkflowTimelineWeb.UndoLive do
  @moduledoc """
  The same incident workflow as the timeline page, with undo turned on.

  Two things are on screen at once, and the point is that they disagree:

  - **The band** is drawn from history, and a toggle switches it between the
    literal reading (`history/2`) and the corrected one
    (`history(effective: true)`). Undo a transition and the segment it created
    vanishes from the corrected band while staying in the literal one.
  - **The log table** always shows every row, including the ones the corrected
    band drops — struck through, with the undo row that reversed each of them
    pointing back at it.

  That pairing is the whole argument for `undoes_id` over an `undone` flag:
  had the reversed row been flagged and filtered, the left-hand reading would
  not exist to compare against.
  """

  use WorkflowTimelineWeb, :live_view

  alias AshWorkflow.TransitionLog
  alias WorkflowTimeline.IncidentResponse
  alias WorkflowTimeline.IncidentResponse.UndoableIncident
  alias WorkflowTimeline.Seeder

  @state_colors %{
    triaging: "bg-amber-400",
    investigating: "bg-blue-500",
    escalated: "bg-red-600",
    resolved: "bg-emerald-500",
    triage_failed: "bg-stone-500"
  }

  @state_labels %{
    triaging: "Triaging",
    investigating: "Investigating",
    escalated: "Escalated",
    resolved: "Resolved",
    triage_failed: "Triage failed"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(effective: false) |> load_incidents()}
  end

  @impl true
  def handle_event("toggle_effective", _params, socket) do
    {:noreply, assign(socket, effective: !socket.assigns.effective)}
  end

  @impl true
  def handle_event("seed", _params, socket) do
    Seeder.seed_undoable_incident!()
    {:noreply, load_incidents(socket)}
  end

  @impl true
  def handle_event("transition", %{"id" => id, "action" => action}, socket) do
    action = String.to_existing_atom(action)

    id
    |> fetch!()
    |> Ash.update!(action: action, actor: Seeder.any_responder(), authorize?: false)

    {:noreply, load_incidents(socket)}
  end

  @impl true
  def handle_event("undo", %{"id" => id}, socket) do
    incident = fetch!(id)

    case Ash.update(incident, action: :undo, actor: Seeder.any_responder(), authorize?: false) do
      {:ok, _incident} ->
        {:noreply, load_incidents(socket)}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, refusal_message(error)) |> load_incidents()}
    end
  end

  defp fetch!(id) do
    Ash.get!(UndoableIncident, id, authorize?: false)
  end

  # `UndoNotPermitted` carries a `reason` atom precisely so a caller does not
  # have to match on message text. The page shows the message anyway, because
  # a human is reading it.
  defp refusal_message(%{errors: [%{__struct__: mod} = error | _]})
       when mod == AshWorkflow.Errors.UndoNotPermitted do
    Exception.message(error)
  end

  defp refusal_message(error), do: Exception.message(error)

  defp load_incidents(socket) do
    %{results: incidents} =
      IncidentResponse.list_undoable_incidents!(authorize?: false)

    assign(socket, cards: Enum.map(incidents, &build_card/1))
  end

  defp build_card(incident) do
    history = UndoableIncident.history(incident)
    effective = TransitionLog.effective(history)
    effective_ids = MapSet.new(effective, & &1.id)

    %{
      incident: incident,
      history: history,
      reversed_ids:
        history |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.difference(effective_ids),
      undoes_by_id: Map.new(history, &{&1.id, &1.undoes_id}),
      segments: segments_from_history(history),
      effective_segments: segments_from_history(effective),
      undo_target: UndoableIncident.undo_target(incident),
      available: AshWorkflow.Info.available_actions(UndoableIncident, incident.state)
    }
  end

  # Same derivation as the timeline page: a row where `from_state == to_state`
  # is an every firing, not a state change, so it becomes a tick rather than a
  # new segment.
  defp segments_from_history([]), do: []

  defp segments_from_history([first | rest]) do
    initial = [%{state: first.to_state, start: first.occurred_at, ticks: []}]

    rest
    |> Enum.reduce(initial, fn row, [current | earlier] ->
      if row.from_state == row.to_state do
        [%{current | ticks: current.ticks ++ [row.occurred_at]} | earlier]
      else
        [%{state: row.to_state, start: row.occurred_at, ticks: []}, current | earlier]
      end
    end)
    |> Enum.reverse()
  end

  defp shown_segments(card, true), do: card.effective_segments
  defp shown_segments(card, false), do: card.segments

  defp segment_widths([]), do: []

  defp segment_widths(segments) do
    count = length(segments)
    Enum.map(segments, fn segment -> {segment, Float.round(100 / count, 3)} end)
  end

  defp state_color(state), do: Map.get(@state_colors, state, "bg-stone-300")
  defp state_label(nil), do: "—"
  defp state_label(state), do: Map.get(@state_labels, state, to_string(state))

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d %H:%M:%S")

  defp row_index(history, nil), do: (_ = history) && nil

  defp row_index(history, id) do
    case Enum.find_index(history, &(&1.id == id)) do
      nil -> nil
      index -> index + 1
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-stone-900 text-stone-100 p-6">
      <header class="mb-6">
        <div class="flex items-center gap-4">
          <h1 class="text-3xl font-black">Incident undo</h1>
          <.link navigate={~p"/"} class="text-blue-400 hover:text-blue-300 underline">
            ← back to the timeline
          </.link>
        </div>
        <p class="text-stone-400 mt-1">
          The same workflow, with every manual transition marked <code class="text-stone-200">undoable?: true</code>. Undo appends a row pointing at the
          one it reverses — it never edits or deletes it — so the same log can be read two ways.
        </p>

        <div class="mt-3 flex items-center gap-3">
          <button
            phx-click="seed"
            class="bg-blue-600 hover:bg-blue-700 px-4 py-2 rounded font-bold"
          >
            Add an incident
          </button>
          <button
            phx-click="toggle_effective"
            class={
              "px-4 py-2 rounded font-bold " <>
                if(@effective,
                  do: "bg-emerald-600 hover:bg-emerald-700",
                  else: "bg-stone-700 hover:bg-stone-600"
                )
            }
          >
            {if @effective, do: "Showing: corrected history", else: "Showing: what happened"}
          </button>
          <span class="text-sm text-stone-400">
            {if @effective,
              do: "history(effective: true) — rows a later undo reversed are dropped",
              else: "history/1 — every row, including states rewound out of"}
          </span>
        </div>
      </header>

      <div :if={@flash[:error]} class="mb-4 bg-red-900/60 border border-red-600 rounded p-3 text-sm">
        {@flash[:error]}
      </div>

      <div class="space-y-4">
        <div :for={card <- @cards} class="bg-stone-800 rounded-xl p-4">
          <div class="flex items-center justify-between mb-3">
            <div>
              <span class="font-bold">{card.incident.title}</span>
              <span class="text-xs text-stone-400 ml-2">{card.incident.severity}</span>
            </div>
            <div class="flex items-center gap-2">
              <span class={"px-2 py-0.5 rounded text-xs font-bold " <> state_color(card.incident.state)}>
                {state_label(card.incident.state)}
              </span>
              <button
                :for={action <- card.available}
                phx-click="transition"
                phx-value-id={card.incident.id}
                phx-value-action={action}
                class="bg-stone-700 hover:bg-stone-600 px-3 py-1 rounded text-xs font-bold"
              >
                {action}
              </button>
              <button
                :if={card.undo_target}
                phx-click="undo"
                phx-value-id={card.incident.id}
                class="bg-amber-600 hover:bg-amber-500 px-3 py-1 rounded text-xs font-bold"
              >
                undo → {state_label(card.undo_target)}
              </button>
              <span
                :if={is_nil(card.undo_target)}
                class="px-3 py-1 rounded text-xs font-bold bg-stone-900 text-stone-500"
                title="The last state change was not an undoable transition"
              >
                nothing to undo
              </span>
            </div>
          </div>

          <div class="relative h-8 bg-stone-900 rounded overflow-hidden flex">
            <div
              :for={{segment, width} <- segment_widths(shown_segments(card, @effective))}
              class={"h-full " <> state_color(segment.state)}
              style={"width: #{width}%;"}
              title={state_label(segment.state)}
            >
            </div>
          </div>

          <table class="w-full mt-3 text-xs">
            <thead class="text-stone-500">
              <tr class="text-left">
                <th class="py-1 w-8">#</th>
                <th class="py-1">when</th>
                <th class="py-1">from → to</th>
                <th class="py-1">transition</th>
                <th class="py-1">triggered by</th>
                <th class="py-1">undoes</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{row, index} <- Enum.with_index(card.history, 1)}
                class={
                  if MapSet.member?(card.reversed_ids, row.id),
                    do: "text-stone-500 line-through",
                    else: "text-stone-200"
                }
              >
                <td class="py-1">{index}</td>
                <td class="py-1">{format_time(row.occurred_at)}</td>
                <td class="py-1">{state_label(row.from_state)} → {state_label(row.to_state)}</td>
                <td class="py-1">{row.transition_name}</td>
                <td class="py-1">
                  <span class={
                    "px-1.5 py-0.5 rounded " <>
                      if(row.triggered_by == :undo, do: "bg-amber-700", else: "bg-stone-700")
                  }>
                    {row.triggered_by}
                  </span>
                </td>
                <td class="py-1">
                  <span :if={row.undoes_id} class="text-amber-400 no-underline">
                    ↩ row {row_index(card.history, row.undoes_id)}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
