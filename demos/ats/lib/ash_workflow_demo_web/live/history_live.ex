defmodule AshWorkflowDemoWeb.HistoryLive do
  @moduledoc """
  Every candidate's transition log: where they came from, where they went,
  which transition ran, when, and what triggered it — a person (El Jefe's
  buttons, the DBS portal), an automatic step (Janine, Steve), a timeout, or
  an error path.

  Also the undo page. `Candidate.undo_target/1` names the state the most
  recent undoable transition would rewind to, or `nil` when the last change
  was not one of `:offer`, `:veto`, `:dbs_clear`, or `:dbs_flag`. Clicking
  undo appends a row pointing at the one it reverses rather than editing or
  deleting it, so the log can be read two ways from the same rows — the
  **Showing: what happened / corrected history** toggle switches which
  reading the band below each candidate is drawn from. Undoing an undo is a
  redo: it reverses the undo row, which is why one button does both.
  """

  use AshWorkflowDemoWeb, :live_view

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate

  @state_colors %{
    hr_screen: "bg-amber-500",
    hr_decision: "bg-amber-500",
    background_check: "bg-purple-600",
    bureau_result: "bg-purple-600",
    lead_interview: "bg-indigo-600",
    lead_decision: "bg-indigo-600",
    final_approval: "bg-teal-600",
    hired: "bg-emerald-600",
    rejected: "bg-stone-600"
  }

  @state_labels %{
    hr_screen: "HR screen",
    hr_decision: "HR screen",
    background_check: "DBS check",
    bureau_result: "DBS check",
    lead_interview: "Lead interview",
    lead_decision: "Lead interview",
    final_approval: "El Jefe",
    hired: "Hired",
    rejected: "Rejected"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AshWorkflowDemo.PubSub, "candidates:all")
    end

    {:ok, socket |> assign(effective: false) |> load_cards()}
  end

  @impl true
  def handle_info({:candidate_changed, _id}, socket), do: {:noreply, load_cards(socket)}

  @impl true
  def handle_event("toggle_effective", _params, socket) do
    {:noreply, assign(socket, effective: !socket.assigns.effective)}
  end

  @impl true
  def handle_event("undo", %{"id" => id}, socket) do
    candidate = fetch!(id)

    case Ash.update(candidate, action: :undo, authorize?: false) do
      {:ok, _candidate} ->
        {:noreply, load_cards(socket)}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, refusal_message(error)) |> load_cards()}
    end
  end

  defp fetch!(id), do: Ash.get!(Candidate, id, authorize?: false)

  # `UndoNotPermitted` carries a `reason` atom precisely so a caller does not
  # have to match on message text. The page shows the message anyway, because
  # a human is reading it.
  defp refusal_message(%{errors: [%{__struct__: mod} = error | _]})
       when mod == AshWorkflow.Errors.UndoNotPermitted do
    Exception.message(error)
  end

  defp refusal_message(error), do: Exception.message(error)

  defp load_cards(socket) do
    %{results: candidates} = ATS.list_candidates!(authorize?: false)

    cards =
      candidates
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.map(&build_card/1)

    assign(socket, cards: cards)
  end

  defp build_card(candidate) do
    history = Candidate.history(candidate)
    effective = AshWorkflow.TransitionLog.effective(history)
    effective_ids = MapSet.new(effective, & &1.id)

    %{
      candidate: candidate,
      history: history,
      reversed_ids:
        history |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.difference(effective_ids),
      segments: segments_from_history(history),
      effective_segments: segments_from_history(effective),
      undo_target: Candidate.undo_target(candidate)
    }
  end

  # ATS has no repeating timeout (unlike the reference incident-response
  # workflow's :status_reminder), so from_state == to_state never happens here
  # and `ticks` stays empty — kept anyway because it's the same, already-tested
  # derivation `Incident.history/1` bands are built from.
  defp segments_from_history([]), do: []

  defp segments_from_history([first | rest]) do
    initial = [%{state: first.to_state, ticks: []}]

    rest
    |> Enum.reduce(initial, fn row, [current | earlier] ->
      if row.from_state == row.to_state do
        [%{current | ticks: current.ticks ++ [row.occurred_at]} | earlier]
      else
        [%{state: row.to_state, ticks: []}, current | earlier]
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

  defp trigger_label(:initial), do: "submitted"
  defp trigger_label(:automatic), do: "automatic step"
  defp trigger_label(:manual), do: "person"
  defp trigger_label(:timeout), do: "timeout"
  defp trigger_label(:error_path), do: "error path"
  defp trigger_label(:undo), do: "undo"
  defp trigger_label(other), do: to_string(other)

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

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
          <h1 class="text-3xl font-black">Candidate history</h1>
          <.link navigate={~p"/"} class="text-blue-400 hover:text-blue-300 underline">
            ← the kanban
          </.link>
          <.link navigate={~p"/rewind"} class="text-blue-400 hover:text-blue-300 underline">
            the playhead →
          </.link>
        </div>
        <p class="text-stone-400 mt-1">
          Every hop between steps, read from the transition log rather than the current
          <code class="text-stone-200">state</code>
          column. <code class="text-stone-200">:offer</code>, <code class="text-stone-200">:veto</code>,
          and the bureau's <code class="text-stone-200">:dbs_clear</code>
          / <code class="text-stone-200">:dbs_flag</code>
          can be undone within 30 minutes — undo appends a row pointing at the one it reverses,
          it never edits or deletes it.
        </p>

        <div class="mt-3 flex items-center gap-3">
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
            <div class="flex items-center gap-3">
              <img src={card.candidate.avatar_url} class="w-10 h-10 rounded-full bg-stone-200" />
              <span class="font-bold">{card.candidate.name}</span>
            </div>
            <div class="flex items-center gap-2">
              <span class={
                "px-2 py-0.5 rounded text-xs font-bold " <> state_color(card.candidate.state)
              }>
                {state_label(card.candidate.state)}
              </span>
              <button
                :if={card.undo_target}
                phx-click="undo"
                phx-value-id={card.candidate.id}
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
                    {trigger_label(row.triggered_by)}
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
