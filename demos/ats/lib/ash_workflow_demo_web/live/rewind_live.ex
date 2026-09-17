defmodule AshWorkflowDemoWeb.RewindLive do
  @moduledoc """
  A draggable playhead over every candidate at once, resolving each one's
  state at that instant from its transition log rather than its current
  `state` column.

  Each band is built once, on mount and whenever a candidate changes, from
  `Candidate.history/1`. Dragging the slider then re-derives "state at this
  instant" locally by walking each band's own segment list — the same logic
  `state_at/2` exposes as a code interface function, just applied to data
  already loaded in the socket instead of re-querying per drag event.

  This is log-backed and live, deliberately not built on Ash temporal
  resources / Postgres 19 — that is a separate, future piece.
  """

  use AshWorkflowDemoWeb, :live_view

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate

  @slider_steps 1000

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

    {:ok, load_bands(socket, slider_position: @slider_steps)}
  end

  @impl true
  def handle_info({:candidate_changed, _id}, socket) do
    {:noreply, load_bands(socket, slider_position: socket.assigns.slider_position)}
  end

  @impl true
  def handle_event("slide", %{"at" => at}, socket) do
    position = at |> String.to_integer() |> clamp(0, @slider_steps)
    {:noreply, assign(socket, slider_position: position, playhead: playhead_at(socket, position))}
  end

  defp load_bands(socket, slider_position: slider_position) do
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
      slider_position: slider_position
    )
    |> assign(playhead: playhead_from_window(window_start, window_end, slider_position))
  end

  defp build_band(candidate) do
    history = Candidate.history(candidate)
    segments = segments_from_history(history)

    %{candidate: candidate, history: history, segments: segments}
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

  defp time_window(bands) do
    all_times = Enum.flat_map(bands, fn band -> Enum.map(band.history, & &1.occurred_at) end)
    now = DateTime.utc_now()

    case all_times do
      [] -> {DateTime.add(now, -1, :hour), now}
      times -> {Enum.min(times, DateTime), now}
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

  defp state_color(state), do: Map.get(@state_colors, state, "bg-stone-300")
  defp state_label(nil), do: "—"
  defp state_label(state), do: Map.get(@state_labels, state, to_string(state))

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-stone-900 text-stone-100 p-6">
      <header class="mb-6">
        <div class="flex items-center gap-4">
          <h1 class="text-3xl font-black">Rewind</h1>
          <.link navigate={~p"/"} class="text-blue-400 hover:text-blue-300 underline">
            ← the kanban
          </.link>
          <.link navigate={~p"/history"} class="text-blue-400 hover:text-blue-300 underline">
            ← the transition log
          </.link>
        </div>
        <p class="text-stone-400">
          Drag the playhead to see what every candidate's step was at that instant — derived from
          the transition log, not from the current row.
        </p>
      </header>

      <div class="bg-stone-800 rounded-xl p-4 mb-6">
        <div class="flex items-center justify-between text-sm text-stone-400 mb-2">
          <span>{format_time(@window_start)}</span>
          <span class="font-bold text-stone-100">Playhead: {format_time(@playhead)}</span>
          <span>{format_time(@window_end)}</span>
        </div>
        <form phx-change="slide" id="playhead-form">
          <input type="range" name="at" min="0" max="1000" value={@slider_position} class="w-full" />
        </form>
      </div>

      <div class="space-y-4">
        <%= for band <- @bands do %>
          <div class="bg-stone-800 rounded-xl p-4">
            <div class="flex items-center justify-between mb-2">
              <div class="flex items-center gap-3">
                <img src={band.candidate.avatar_url} class="w-8 h-8 rounded-full bg-stone-200" />
                <span class="font-bold">{band.candidate.name}</span>
              </div>
              <div class="text-sm">
                <span class="text-stone-400">state at playhead:</span>
                <span class={
                  "ml-1 px-2 py-0.5 rounded text-xs font-bold " <>
                    state_color(state_at_playhead(band.segments, @playhead))
                }>
                  {state_label(state_at_playhead(band.segments, @playhead))}
                </span>
              </div>
            </div>

            <div class="relative h-8 bg-stone-900 rounded overflow-hidden">
              <%= for {segment, next_start} <- segments_with_next_start(band.segments) do %>
                <div
                  class={"absolute inset-y-0 " <> state_color(segment.state)}
                  style={segment_style(segment, next_start, @window_start, @window_end)}
                  title={state_label(segment.state)}
                >
                </div>
                <%= for tick <- segment.ticks do %>
                  <div
                    class="absolute inset-y-0 w-0.5 bg-white/80"
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
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
