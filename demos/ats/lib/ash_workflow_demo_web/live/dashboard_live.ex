defmodule AshWorkflowDemoWeb.DashboardLive do
  use AshWorkflowDemoWeb, :live_view

  require Ash.Query

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.TunnelUrl

  @columns [
    {:verifying, "Verifying", "bg-amber-100"},
    {:review, "Review", "bg-blue-100"},
    {:hired, "Hired", "bg-emerald-100"},
    {:rejected, "Rejected", "bg-stone-100"},
    {:auto_rejected, "Auto-rejected", "bg-stone-100"},
    {:position_filled, "Position filled", "bg-stone-100"}
  ]

  @random_names ~w(Lola Mateo Paco Rosa Diego Carmen Joaquín Isabella Rafa Sofía)
  @random_pitches [
    "I don't sleep. I deploy.",
    "Three ex-unicorns. One mission: yours.",
    "I wrote the stack you use.",
    "I can make the build faster. I bet.",
    "I was recruited by Jesús. He said no. You say yes.",
    "I speak seven languages. Three of them compile."
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AshWorkflowDemo.PubSub, "candidates:all")
      Phoenix.PubSub.subscribe(AshWorkflowDemo.PubSub, "tunnel_url")
      :timer.send_interval(1000, :tick)
    end

    {:ok,
     socket
     |> assign(tunnel_url: TunnelUrl.get(), now: DateTime.utc_now(), selected: nil)
     |> load_candidates()}
  end

  @impl true
  def handle_info({:candidate_changed, _id}, socket) do
    socket = load_candidates(socket)
    # Refresh the selected candidate if one is open
    socket =
      case socket.assigns.selected do
        nil ->
          socket

        %{id: id} ->
          case AshWorkflowDemo.ATS.get_candidate(id) do
            {:ok, c} -> assign(socket, selected: c)
            _ -> assign(socket, selected: nil)
          end
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:tunnel_url_changed, url}, socket),
    do: {:noreply, assign(socket, tunnel_url: url)}

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

  @impl true
  def handle_event("hire", %{"id" => id}, socket) do
    {:ok, c} = ATS.get_candidate(id)
    {:ok, _} = ATS.hire(c, %{}, authorize?: false)
    {:noreply, load_candidates(socket)}
  end

  @impl true
  def handle_event("reject", %{"id" => id}, socket) do
    {:ok, c} = ATS.get_candidate(id)
    {:ok, _} = ATS.reject(c, %{}, authorize?: false)
    {:noreply, load_candidates(socket)}
  end

  @impl true
  def handle_event("reset", _, socket) do
    # Only :review candidates can transition to :position_filled via the workflow.
    # :submitted/:verifying ones auto-progress within ~5s and can be reset on a
    # second click.
    %{results: to_reset} =
      ATS.Candidate
      |> Ash.Query.filter(state == :review)
      |> Ash.read!(authorize?: false)

    Enum.each(to_reset, &ATS.position_filled!(&1, %{}, authorize?: false))
    {:noreply, load_candidates(socket)}
  end

  @impl true
  def handle_event("insert_random", _, socket) do
    name = Enum.random(@random_names) <> " " <> (:crypto.strong_rand_bytes(2) |> Base.encode16())
    pitch = Enum.random(@random_pitches)
    avatar = "https://api.dicebear.com/7.x/avataaars/svg?seed=#{URI.encode(name)}"
    {:ok, _} = ATS.start(name, pitch, avatar)
    {:noreply, load_candidates(socket)}
  end

  @impl true
  def handle_event("set_tunnel", %{"url" => url}, socket) do
    TunnelUrl.set(url)
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_card", %{"id" => id}, socket) do
    case ATS.get_candidate(id) do
      {:ok, c} -> {:noreply, assign(socket, selected: c)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_card", _, socket), do: {:noreply, assign(socket, selected: nil)}

  defp load_candidates(socket) do
    %{results: candidates} = ATS.list_candidates!(authorize?: false)
    by_state = Enum.group_by(candidates, &column_for(&1.state))
    assign(socket, by_state: by_state)
  end

  # :submitted is the wait state a candidate sits in until :verify_after passes.
  # The board shows it in the same column as :verifying: from the audience's
  # side it is one "we are looking at your application" phase.
  defp column_for(:submitted), do: :verifying
  defp column_for(state), do: state

  defp qr_svg(url) do
    url
    |> EQRCode.encode()
    |> EQRCode.svg(color: "#7f1d1d", width: 200)
    |> Phoenix.HTML.raw()
  end

  defp seconds_since(%DateTime{} = t, now), do: DateTime.diff(now, t, :second)
  defp seconds_since(_, _), do: 0

  defp state_label(:submitted), do: {"Verifying", "bg-amber-500"}
  defp state_label(:verifying), do: {"Verifying", "bg-amber-500"}
  defp state_label(:review), do: {"Under review", "bg-blue-600"}
  defp state_label(:hired), do: {"Hired", "bg-emerald-600"}
  defp state_label(:rejected), do: {"Rejected", "bg-stone-600"}
  defp state_label(:auto_rejected), do: {"Auto-rejected", "bg-stone-600"}
  defp state_label(:position_filled), do: {"Position filled", "bg-stone-600"}
  defp state_label(:verification_failed), do: {"Verification failed", "bg-red-600"}
  defp state_label(_), do: {"—", "bg-stone-400"}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, columns: @columns)

    ~H"""
    <div class="min-h-screen bg-stone-900 text-stone-100 p-6">
      <header class="flex items-start justify-between mb-6 gap-6">
        <div class="flex-1">
          <h1 class="text-4xl font-black">🤠 El Jefe's Kanban</h1>
          <p class="text-stone-400">One slot. Many candidates. Decide fast.</p>
          <div class="mt-4 flex gap-3">
            <button
              phx-click="insert_random"
              class="bg-amber-600 hover:bg-amber-700 px-4 py-2 rounded font-bold"
            >
              Insert Random Candidate
            </button>
            <button
              phx-click="reset"
              data-confirm="Reset the req? This clears review-stage candidates."
              class="bg-red-700 hover:bg-red-800 px-4 py-2 rounded font-bold"
            >
              Reset the Req
            </button>
          </div>
        </div>
        <div class="text-center shrink-0">
          <%= if @tunnel_url do %>
            <div class="bg-white p-3 rounded inline-block">
              {qr_svg(@tunnel_url <> "/apply")}
            </div>
            <div class="text-xs mt-2 text-stone-400">{@tunnel_url}/apply</div>
          <% else %>
            <form phx-submit="set_tunnel" class="bg-stone-800 p-4 rounded">
              <div class="text-sm mb-2 font-bold">Paste tunnel URL</div>
              <input
                name="url"
                class="text-stone-900 px-2 py-1 rounded w-72"
                placeholder="https://xxx.trycloudflare.com"
              />
              <button class="ml-2 bg-amber-600 px-3 py-1 rounded font-bold">Set</button>
            </form>
          <% end %>
        </div>
      </header>

      <div class="grid grid-cols-6 gap-4 w-full">
        <%= for {state, title, bg} <- @columns do %>
          <div class={"rounded-xl p-4 min-h-[70vh] " <> bg <> " text-stone-900"}>
            <div class="flex items-center justify-between mb-3">
              <h2 class="font-bold text-lg">{title}</h2>
              <span class="text-sm bg-stone-900 text-stone-100 rounded-full px-2.5 py-0.5 font-semibold">
                {length(Map.get(@by_state, state, []))}
              </span>
            </div>
            <div class="space-y-3">
              <%= for c <- Map.get(@by_state, state, []) do %>
                <div
                  phx-click="open_card"
                  phx-value-id={c.id}
                  class="bg-white rounded-lg p-3 shadow cursor-pointer hover:shadow-lg hover:-translate-y-0.5 transition"
                >
                  <div class="flex items-center gap-3">
                    <img src={c.avatar_url} class="w-12 h-12 rounded-full bg-stone-200 shrink-0" />
                    <div class="min-w-0 flex-1">
                      <div class="font-bold text-sm truncate">{c.name}</div>
                      <%= if c.score do %>
                        <div class="text-xs text-stone-500">{c.score}/10</div>
                      <% end %>
                    </div>
                  </div>
                  <div class="text-xs text-stone-600 mt-2 italic line-clamp-2">"{c.pitch}"</div>

                  <%= if state == :review do %>
                    <div class="text-xs text-red-700 font-bold mt-2">
                      {max(0, 30 - seconds_since(c.state_entered_at, @now))}s left
                    </div>
                    <div class="flex gap-1 mt-2">
                      <button
                        phx-click="hire"
                        phx-value-id={c.id}
                        class="flex-1 bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold py-1.5 rounded"
                      >
                        Hire
                      </button>
                      <button
                        phx-click="reject"
                        phx-value-id={c.id}
                        class="flex-1 bg-red-700 hover:bg-red-800 text-white text-xs font-bold py-1.5 rounded"
                      >
                        Reject
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <%= if @selected do %>
        <% {label, color} = state_label(@selected.state) %>
        <div
          phx-window-keydown="close_card"
          phx-key="Escape"
          class="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center p-6 z-50"
        >
          <div
            phx-click-away="close_card"
            class="bg-white text-stone-900 rounded-2xl max-w-lg w-full shadow-2xl overflow-hidden"
          >
            <div class={"p-6 text-white " <> color}>
              <div class="flex items-center gap-4">
                <img src={@selected.avatar_url} class="w-20 h-20 rounded-full bg-white p-1 shadow" />
                <div class="flex-1 min-w-0">
                  <div class="text-2xl font-extrabold truncate">{@selected.name}</div>
                  <div class="text-sm opacity-90">{label}</div>
                </div>
                <button
                  phx-click="close_card"
                  class="text-white/80 hover:text-white text-2xl leading-none"
                >
                  &times;
                </button>
              </div>
            </div>
            <div class="p-6 space-y-4">
              <div>
                <div class="text-xs uppercase tracking-wider text-stone-500">Pitch</div>
                <div class="mt-1 italic">"{@selected.pitch}"</div>
              </div>

              <%= if @selected.score do %>
                <div class="bg-stone-100 rounded-xl p-4">
                  <div class="text-xs uppercase tracking-wider text-stone-500">Verify score</div>
                  <div class="flex items-baseline gap-2 mt-1">
                    <div class="text-4xl font-black">
                      {@selected.score}<span class="text-lg text-stone-400">/10</span>
                    </div>
                    <div class="text-sm text-stone-600 italic">"{@selected.score_reason}"</div>
                  </div>
                </div>
              <% end %>

              <div class="text-xs text-stone-500">
                Submitted {Calendar.strftime(@selected.inserted_at, "%H:%M:%S")} &middot; In state since {Calendar.strftime(
                  @selected.state_entered_at,
                  "%H:%M:%S"
                )}
              </div>

              <%= if @selected.state == :review do %>
                <div class="flex gap-2 pt-2">
                  <button
                    phx-click="hire"
                    phx-value-id={@selected.id}
                    class="flex-1 bg-emerald-600 hover:bg-emerald-700 text-white font-bold py-3 rounded-lg"
                  >
                    Hire
                  </button>
                  <button
                    phx-click="reject"
                    phx-value-id={@selected.id}
                    class="flex-1 bg-red-700 hover:bg-red-800 text-white font-bold py-3 rounded-lg"
                  >
                    Reject
                  </button>
                </div>
                <div class="text-center text-xs text-red-700 font-bold">
                  {max(0, 30 - seconds_since(@selected.state_entered_at, @now))}s until auto-reject
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
