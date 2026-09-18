defmodule AshWorkflowDemoWeb.TimelineLive do
  @moduledoc """
  One page over the transition log, serving both readings of it.

  A draggable playhead runs across every candidate at once, resolving each
  one's state at that instant from its log rather than from its current
  `state` column. Clicking a candidate unfolds the rows behind its band:
  where it came from, where it went, which transition ran, when, and what
  triggered it — a person (El Jefe's buttons, the DBS portal), an automatic
  step (Janine, Steve), a timeout, or an error path.

  The two readings share the playhead. An unfolded list shows only the rows
  at or before it, so scrubbing back takes events off the list and scrubbing
  forward puts them back.

  The window spans the first logged event to a minute past the last one, so
  it stays the width of the demo rather than the width of however long the
  server has been up.

  Also the undo page. `Candidate.undo_target/1` names the state the most
  recent undoable transition would rewind to, or `nil` when the last change
  was not one of `:offer`, `:veto`, `:dbs_clear`, or `:dbs_flag`. Clicking
  undo appends a row pointing at the one it reverses rather than editing or
  deleting it. The reversed row stays in the list, struck through, with the
  undo row pointing back at it.

  This is log-backed and live, deliberately not built on Ash temporal
  resources / Postgres 19 — that is a separate, future piece.
  """

  use AshWorkflowDemoWeb, :live_view

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate
  alias AshWorkflowDemoWeb.Palette

  @slider_steps 1000
  @window_padding_seconds 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AshWorkflowDemo.PubSub, "candidates:all")
    end

    {:ok,
     socket
     |> assign(expanded: MapSet.new())
     |> load_bands(@slider_steps)}
  end

  @impl true
  def handle_info({:candidate_changed, _id}, socket) do
    {:noreply, load_bands(socket, socket.assigns.slider_position)}
  end

  @impl true
  def handle_event("slide", %{"at" => at}, socket) do
    position = at |> String.to_integer() |> clamp(0, @slider_steps)
    {:noreply, assign(socket, slider_position: position, playhead: playhead_at(socket, position))}
  end

  @impl true
  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, expanded: expanded)}
  end

  @impl true
  def handle_event("undo", %{"id" => id}, socket) do
    candidate = Ash.get!(Candidate, id, authorize?: false)

    case Ash.update(candidate, action: :undo, authorize?: false) do
      {:ok, _candidate} ->
        {:noreply, load_bands(socket, socket.assigns.slider_position)}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal_message(error))
         |> load_bands(socket.assigns.slider_position)}
    end
  end

  # `UndoNotPermitted` carries a `reason` atom precisely so a caller does not
  # have to match on message text. The page shows the message anyway, because
  # a human is reading it.
  defp refusal_message(%{errors: [%{__struct__: mod} = error | _]})
       when mod == AshWorkflow.Errors.UndoNotPermitted do
    Exception.message(error)
  end

  defp refusal_message(error), do: Exception.message(error)

  defp load_bands(socket, slider_position) do
    %{results: candidates} = ATS.list_candidates!(authorize?: false)

    bands =
      candidates
      |> Enum.sort_by(& &1.inserted_at, DateTime)
      |> Enum.map(&build_band/1)

    {window_start, window_end} = time_window(bands)

    socket
    |> assign(
      bands: bands,
      window_start: window_start,
      window_end: window_end,
      slider_position: slider_position,
      playhead: playhead_from_window(window_start, window_end, slider_position)
    )
  end

  defp build_band(candidate) do
    history = Candidate.history(candidate)
    effective_ids = history |> AshWorkflow.TransitionLog.effective() |> MapSet.new(& &1.id)

    %{
      candidate: candidate,
      history: Enum.with_index(history, 1),
      reversed_ids: history |> MapSet.new(& &1.id) |> MapSet.difference(effective_ids),
      segments: segments_from_history(history),
      undo_target: Candidate.undo_target(candidate)
    }
  end

  # ATS has no repeating timeout, so from_state == to_state never happens and
  # no tick ever renders — kept as the same derivation the reference
  # incident-response demo's bands are tested against.
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

  # The window ends a minute past the last logged event rather than at `now`.
  # Anchoring it to the wall clock stretches the window for as long as the
  # demo is left running, which squeezes every band into the left edge and
  # makes scrubbing back through them unusable. A live candidate's last
  # segment still runs to the end of the window either way.
  defp time_window(bands) do
    all_times = Enum.flat_map(bands, fn band -> Enum.map(band.segments, & &1.start) end)
    now = DateTime.utc_now()

    case all_times do
      [] ->
        {DateTime.add(now, -@window_padding_seconds, :second), now}

      times ->
        {Enum.min(times, DateTime),
         times |> Enum.max(DateTime) |> DateTime.add(@window_padding_seconds, :second)}
    end
  end

  defp playhead_from_window(window_start, window_end, position) do
    fraction = position / @slider_steps
    total_ms = DateTime.diff(window_end, window_start, :millisecond)
    DateTime.add(window_start, round(total_ms * fraction), :millisecond)
  end

  defp playhead_at(socket, position) do
    playhead_from_window(socket.assigns.window_start, socket.assigns.window_end, position)
  end

  defp state_at_playhead(segments, playhead) do
    segments
    |> Enum.filter(&(DateTime.compare(&1.start, playhead) != :gt))
    |> List.last()
    |> case do
      nil -> nil
      segment -> segment.state
    end
  end

  defp rows_through_playhead(history, playhead) do
    Enum.filter(history, fn {row, _index} ->
      DateTime.compare(row.occurred_at, playhead) != :gt
    end)
  end

  defp segment_style(segment, next_start, window_start, window_end) do
    finish = next_start || window_end
    total = max(DateTime.diff(window_end, window_start, :millisecond), 1)
    left = percent(DateTime.diff(segment.start, window_start, :millisecond), total)
    width = percent(DateTime.diff(finish, segment.start, :millisecond), total)
    "left: #{left}%; width: #{width}%;"
  end

  defp tick_style(tick, window_start, window_end) do
    total = max(DateTime.diff(window_end, window_start, :millisecond), 1)
    left = percent(DateTime.diff(tick, window_start, :millisecond), total)
    "left: #{left}%;"
  end

  defp percent(ms, total_ms), do: Float.round(ms / total_ms * 100, 3)

  defp playhead_style(window_start, window_end, playhead) do
    total = max(DateTime.diff(window_end, window_start, :millisecond), 1)
    left = percent(DateTime.diff(playhead, window_start, :millisecond), total)
    "left: #{left}%;"
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  defp segments_with_next_start([]), do: []

  defp segments_with_next_start(segments) do
    starts = Enum.map(segments, & &1.start)
    next_starts = tl(starts) ++ [nil]
    Enum.zip(segments, next_starts)
  end

  defp state_style(state), do: "background: #{Palette.hex(state)}"

  defp trigger_label(:initial), do: "submitted"
  defp trigger_label(:automatic), do: "automatic step"
  defp trigger_label(:manual), do: "person"
  defp trigger_label(:timeout), do: "timeout"
  defp trigger_label(:error_path), do: "error path"
  defp trigger_label(:undo), do: "undo"
  defp trigger_label(other), do: to_string(other)

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp row_index(history, id) do
    case Enum.find(history, fn {row, _index} -> row.id == id end) do
      nil -> nil
      {_row, index} -> index
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-ink text-paper p-6">
      <header class="mb-6">
        <div class="flex items-center gap-4">
          <h1 class="text-3xl font-black">Timeline</h1>
          <.link navigate={~p"/"} class="text-accent-alt hover:text-accent underline">
            ← the kanban
          </.link>
        </div>
        <p class="text-paper-muted mt-1">
          Drag the playhead to see what every candidate's step was at that instant, read from the
          transition log rather than the current <code class="text-paper">state</code>
          column. Click a candidate to unfold the rows behind its band. <code class="text-paper">:offer</code>, <code class="text-paper">:veto</code>,
          and the bureau's <code class="text-paper">:dbs_clear</code>
          / <code class="text-paper">:dbs_flag</code>
          can be undone within 30 minutes — undo appends a row pointing at the one it reverses,
          it never edits or deletes it.
        </p>
      </header>

      <div :if={@flash[:error]} class="mb-4 bg-red-900/60 border border-red-600 rounded p-3 text-sm">
        {@flash[:error]}
      </div>

      <div class="bg-ink-raised rounded-xl p-4 mb-6 sticky top-0 z-10">
        <div class="flex items-center justify-between text-sm text-paper-muted mb-2">
          <span>{format_time(@window_start)}</span>
          <span class="font-bold text-paper">Playhead: {format_time(@playhead)}</span>
          <span>{format_time(@window_end)}</span>
        </div>
        <form phx-change="slide" id="playhead-form">
          <input type="range" name="at" min="0" max="1000" value={@slider_position} class="w-full" />
        </form>
      </div>

      <div class="space-y-4">
        <div
          :for={band <- @bands}
          class="bg-ink-raised rounded-xl p-4"
          id={"band-#{band.candidate.id}"}
        >
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-3">
              <button
                phx-click="toggle_expand"
                phx-value-id={band.candidate.id}
                class="text-paper-muted hover:text-paper w-4 text-left"
                aria-label="unfold the transition log"
              >
                {if MapSet.member?(@expanded, band.candidate.id), do: "▾", else: "▸"}
              </button>
              <img src={band.candidate.avatar_url} class="w-8 h-8 rounded-full bg-paper" />
              <.link
                navigate={~p"/c/#{band.candidate.id}"}
                class="font-bold hover:text-accent underline decoration-ink-line"
              >
                {band.candidate.name}
              </.link>
            </div>
            <div class="flex items-center gap-2 text-sm">
              <span class="text-paper-muted">state at playhead:</span>
              <span
                class="px-2 py-0.5 rounded text-xs font-bold text-ink"
                style={state_style(state_at_playhead(band.segments, @playhead))}
              >
                {Palette.label(state_at_playhead(band.segments, @playhead))}
              </span>
              <button
                :if={band.undo_target}
                phx-click="undo"
                phx-value-id={band.candidate.id}
                class="bg-accent hover:bg-accent/80 text-ink px-3 py-1 rounded text-xs font-bold"
              >
                undo → {Palette.label(band.undo_target)}
              </button>
              <span
                :if={is_nil(band.undo_target)}
                class="px-3 py-1 rounded text-xs font-bold bg-ink text-paper-muted"
                title="The last state change was not an undoable transition"
              >
                nothing to undo
              </span>
            </div>
          </div>

          <div
            class="relative h-8 bg-ink rounded overflow-hidden cursor-pointer"
            phx-click="toggle_expand"
            phx-value-id={band.candidate.id}
          >
            <%= for {segment, next_start} <- segments_with_next_start(band.segments) do %>
              <div
                class="absolute inset-y-0"
                style={
                  state_style(segment.state) <>
                    "; " <> segment_style(segment, next_start, @window_start, @window_end)
                }
                title={Palette.label(segment.state)}
              >
              </div>
              <%= for tick <- segment.ticks do %>
                <div
                  class="absolute inset-y-0 w-0.5 bg-paper/80"
                  style={tick_style(tick, @window_start, @window_end)}
                  title="repeat timeout fired"
                >
                </div>
              <% end %>
            <% end %>
            <div
              class="absolute inset-y-0 w-0.5 bg-yellow-300"
              style={playhead_style(@window_start, @window_end, @playhead)}
            >
            </div>
          </div>

          <div :if={MapSet.member?(@expanded, band.candidate.id)}>
            <table class="w-full mt-3 text-xs">
              <thead class="text-paper-muted">
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
                  :for={{row, index} <- rows_through_playhead(band.history, @playhead)}
                  class={
                    if MapSet.member?(band.reversed_ids, row.id),
                      do: "text-paper-muted line-through",
                      else: "text-paper"
                  }
                >
                  <td class="py-1">{index}</td>
                  <td class="py-1">{format_time(row.occurred_at)}</td>
                  <td class="py-1">
                    {Palette.label(row.from_state)} → {Palette.label(row.to_state)}
                  </td>
                  <td class="py-1">{row.transition_name}</td>
                  <td class="py-1">
                    <span class={
                      "px-1.5 py-0.5 rounded " <>
                        if(row.triggered_by == :undo, do: "bg-amber-700", else: "bg-ink-line")
                    }>
                      {trigger_label(row.triggered_by)}
                    </span>
                  </td>
                  <td class="py-1">
                    <span :if={row.undoes_id} class="text-amber-400 no-underline">
                      ↩ row {row_index(band.history, row.undoes_id)}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>

            <p
              :if={length(band.history) > length(rows_through_playhead(band.history, @playhead))}
              class="mt-2 text-xs text-paper-muted italic"
            >
              {length(band.history) - length(rows_through_playhead(band.history, @playhead))} later
              event(s) hidden — drag the playhead right to bring them back.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
