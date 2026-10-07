defmodule AshWorkflowDemoWeb.DashboardLive do
  use AshWorkflowDemoWeb, :live_view

  require Ash.Query

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate.Deadlines
  alias AshWorkflowDemo.TunnelUrl
  alias AshWorkflowDemoWeb.Palette

  @columns [:hr_screen, :background_check, :lead_interview, :final_approval, :hired, :rejected]

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
      :timer.send_interval(1000, :tick)
    end

    {:ok,
     socket
     |> assign(
       tunnel_url: TunnelUrl.get(),
       now: DateTime.utc_now(),
       selected: nil,
       maximised: nil,
       qr_maximised: false
     )
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
          case AshWorkflowDemo.ATS.get_candidate(id, load: [:pending_deadlines]) do
            {:ok, c} -> assign(socket, selected: c)
            _ -> assign(socket, selected: nil)
          end
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

  @impl true
  def handle_event("offer", %{"id" => id}, socket) do
    {:ok, c} = ATS.get_candidate(id)
    {:ok, _} = ATS.offer(c, %{}, authorize?: false)
    {:noreply, load_candidates(socket)}
  end

  @impl true
  def handle_event("veto", %{"id" => id}, socket) do
    {:ok, c} = ATS.get_candidate(id)
    {:ok, _} = ATS.veto(c, %{}, authorize?: false)
    {:noreply, load_candidates(socket)}
  end

  @impl true
  def handle_event("reset", _, socket) do
    AshWorkflowDemo.Repo.truncate_all()
    {:noreply, assign(load_candidates(socket), selected: nil)}
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
  def handle_event("open_card", %{"id" => id}, socket) do
    # Without :pending_deadlines every Deadlines.due_at/2 in the modal returns
    # nil and every countdown reads zero.
    case ATS.get_candidate(id, load: [:pending_deadlines]) do
      {:ok, c} -> {:noreply, assign(socket, selected: c)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_card", _, socket), do: {:noreply, assign(socket, selected: nil)}

  @impl true
  def handle_event("maximise", %{"state" => state}, socket) do
    {:noreply, assign(socket, maximised: String.to_existing_atom(state))}
  end

  @impl true
  def handle_event("close_maximised", _, socket), do: {:noreply, assign(socket, maximised: nil)}

  @impl true
  def handle_event("maximise_qr", _, socket), do: {:noreply, assign(socket, qr_maximised: true)}

  @impl true
  def handle_event("close_maximised_qr", _, socket),
    do: {:noreply, assign(socket, qr_maximised: false)}

  defp load_candidates(socket) do
    %{results: candidates} =
      ATS.list_candidates!(load: [:pending_deadlines], authorize?: false)

    by_state = Enum.group_by(candidates, &column_for(&1.state))
    assign(socket, by_state: by_state)
  end

  # The decision steps resolve within the same call that enters them, so no
  # card ever visibly rests in :hr_decision or :lead_decision — the board
  # files each under the column the candidate was waiting in beforehand.
  # :bureau_result is likewise instantaneous, so it shares the DBS column
  # with :background_check.
  defp column_for(:hr_decision), do: :hr_screen
  defp column_for(:bureau_result), do: :background_check
  defp column_for(:lead_decision), do: :lead_interview
  defp column_for(state), do: state

  # The deadline the card is currently counting down to, and whose clock it is.
  defp waiting_on(:hr_screen), do: {:janine_responds, "Janine comes back in"}
  defp waiting_on(:background_check), do: {:bureau_responds, "Bureau check lapses in"}
  defp waiting_on(:lead_interview), do: {:steve_responds, "Steve comes back in"}
  defp waiting_on(:final_approval), do: {:jefe_no_answer, "Rejected unless El Jefe decides in"}
  defp waiting_on(_state), do: nil

  # The mark on a column. Every reviewer gets a face, the bureau included: it
  # answers on its own schedule and discloses what it likes, so it behaves far
  # more like a character than an institution. The two terminal columns get an
  # icon, because nobody is waiting in them.
  defp reviewer_avatar(:hr_screen), do: "/images/janine-hr.png"
  defp reviewer_avatar(:lead_interview), do: "/images/steve-tech.png"
  defp reviewer_avatar(:final_approval), do: "/images/conor-transparent.png"
  defp reviewer_avatar(:background_check), do: "/images/dbs-bureau-pigeon.png"
  defp reviewer_avatar(_state), do: nil

  # The maximised panel is large enough to use the cut-out portraits from the
  # deck instead of the small square crops the column headers and cards use.
  defp character_portrait(:hr_screen), do: "/images/janine-transparent.png"
  defp character_portrait(:lead_interview), do: "/images/steve-transparent.png"
  defp character_portrait(:final_approval), do: "/images/conor-transparent.png"
  defp character_portrait(:background_check), do: "/images/dbs-bureau-pigeon.png"
  defp character_portrait(_state), do: nil

  defp reviewer_alt(:hr_screen), do: "Janine, HR manager"
  defp reviewer_alt(:lead_interview), do: "Steve, engineering lead"
  defp reviewer_alt(:final_approval), do: "El Jefe, the boss"

  defp reviewer_alt(:background_check),
    do: "The bureau's inspector, a pigeon with a magnifying glass"

  defp reviewer_alt(_state), do: nil

  defp column_icon(:hired), do: "hero-check-badge-solid"
  defp column_icon(:rejected), do: "hero-x-circle-solid"
  defp column_icon(_state), do: nil

  defp qr_svg(url, width \\ 200) do
    url
    |> EQRCode.encode()
    |> EQRCode.svg(color: "#090909", width: width)
    |> Phoenix.HTML.raw()
  end

  # The character behind each column, for the maximised panel.
  defp character(:hr_screen) do
    %{
      name: "Janine",
      role: "Head of People & Culture",
      alt: "Janine, HR manager",
      bio:
        "Owns the req, the scorecard, and the calendar invite you cannot decline. Has turned down better candidates than you for worse reasons, and has the pipeline review slides to prove it.",
      empty: "Nobody in the screen. Janine is updating the scorecard."
    }
  end

  defp character(:background_check) do
    %{
      name: "The Bureau",
      role: "Disclosure & Background Bureau",
      alt: "The Disclosure & Background Bureau crest",
      bio:
        "Checks your past thoroughly, reports it cheerfully, and has never once been asked to explain its filing system.",
      empty: "No outstanding checks. The Bureau is filing."
    }
  end

  defp character(:lead_interview) do
    %{
      name: "Steve",
      role: "Engineering Lead",
      alt: "Steve, engineering lead",
      bio:
        "Runs the interview loop he spent two years complaining about designing. Will forgive almost anything except a rewrite proposal in the first thirty minutes.",
      empty: "Nobody to interview. Steve is in a meeting about meetings."
    }
  end

  defp character(:final_approval) do
    %{
      name: "El Jefe",
      role: "The Boss",
      alt: "El Jefe, the boss",
      bio:
        "One req, one slot, one signature. Everything in the columns to the left of this one is advisory.",
      empty: "Nothing to sign. El Jefe is unavailable."
    }
  end

  defp character(:hired) do
    %{
      name: "Hired",
      role: "The one",
      alt: nil,
      bio: "One slot, filled. Everyone else found out at the same time.",
      empty: "Nobody hired yet."
    }
  end

  defp character(:rejected) do
    %{
      name: "Rejected",
      role: "Everyone else",
      alt: nil,
      bio:
        "Turned down by Janine, turned down by Steve, vetoed by El Jefe, or simply beaten to the only slot.",
      empty: "Nobody rejected yet. Give it a moment."
    }
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, columns: @columns)

    ~H"""
    <div class="min-h-screen bg-cream text-ink p-6">
      <header class="flex items-start justify-between mb-6 gap-6">
        <div class="flex-1">
          <.brandmark class="text-3xl" />
          <p class="text-muted mt-2">
            Janine, the bureau and Steve work it on their own. You only decide at the end.
          </p>
          <div class="mt-4 flex gap-3">
            <button
              phx-click="insert_random"
              class="bg-amber hover:bg-amber/85 text-ink px-4 py-2 rounded-full font-bold shadow-[4px_4px_0_theme(colors.ink)]"
            >
              Insert Random Candidate
            </button>
            <button
              phx-click="reset"
              data-confirm="Reset the board? This deletes every candidate and pending job."
              class="bg-dark hover:bg-dark/85 text-cream px-4 py-2 rounded-full font-bold shadow-[4px_4px_0_theme(colors.ink)]"
            >
              Reset the board
            </button>
          </div>
        </div>
        <div class="text-center shrink-0">
          <%= if @tunnel_url do %>
            <%!-- White, not bg-well: a phone camera wants the full contrast. --%>
            <div
              phx-click="maximise_qr"
              class="bg-white p-3 rounded-2xl inline-block cursor-pointer hover:ring-2 hover:ring-amber transition shadow-[6px_6px_0_theme(colors.ink)]"
            >
              {qr_svg(@tunnel_url <> "/apply")}
            </div>
            <div class="text-xs mt-2 text-muted">{@tunnel_url}/apply</div>
          <% else %>
            <div class="rounded-2xl border border-line bg-paper p-4 text-sm text-muted">
              <div class="font-bold text-ink">No QR code</div>
              Start the server with <code class="text-orange">TUNNEL_URL</code>
              set and it appears here.
            </div>
          <% end %>
        </div>
      </header>

      <div class="grid grid-cols-6 gap-4 w-full">
        <%= for state <- @columns do %>
          <div
            class="rounded-2xl p-4 min-h-[70vh] bg-paper text-ink border-t-4 border-line shadow-[6px_6px_0_theme(colors.line)]"
            style={"border-top-color: #{Palette.hex(state)}"}
          >
            <div
              phx-click="maximise"
              phx-value-state={state}
              class="flex items-center justify-between mb-3 cursor-pointer group"
            >
              <div class="flex items-center gap-2 min-w-0">
                <%= if reviewer_avatar(state) do %>
                  <img
                    src={reviewer_avatar(state)}
                    alt={reviewer_alt(state)}
                    class="w-8 h-8 rounded-full object-cover shrink-0 bg-cream"
                  />
                <% end %>
                <%= if column_icon(state) do %>
                  <span
                    class={column_icon(state) <> " w-7 h-7 shrink-0"}
                    style={"color: #{Palette.hex(state)}"}
                  >
                  </span>
                <% end %>
                <h2 class="font-serif font-bold text-lg whitespace-nowrap">{Palette.label(state)}</h2>
                <span class="text-muted group-hover:text-ink text-sm shrink-0" title="Maximise">
                  ⤢
                </span>
              </div>
              <span class="text-sm bg-ink text-cream rounded-full px-2.5 py-0.5 font-semibold shrink-0">
                {length(Map.get(@by_state, state, []))}
              </span>
            </div>
            <div class="space-y-3">
              <%= for c <- Map.get(@by_state, state, []) do %>
                <.candidate_card c={c} state={state} now={@now} />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <%= if @selected do %>
        <% {label, color} = {Palette.label(@selected.state), Palette.hex(@selected.state)} %>
        <div
          phx-window-keydown="close_card"
          phx-key="Escape"
          class="fixed inset-0 bg-ink/60 backdrop-blur-sm flex items-center justify-center p-6 z-50"
        >
          <div
            phx-click-away="close_card"
            class="bg-paper text-ink border border-line rounded-2xl max-w-lg w-full shadow-2xl overflow-hidden"
          >
            <div class="p-6 text-ink" style={"background: #{color}"}>
              <div class="flex items-center gap-4">
                <img src={@selected.avatar_url} class="w-20 h-20 rounded-full bg-cream p-1 shadow" />
                <div class="flex-1 min-w-0">
                  <div class="text-2xl font-extrabold truncate">{@selected.name}</div>
                  <div class="text-sm opacity-90">{label}</div>
                </div>
                <button
                  phx-click="close_card"
                  class="text-ink/70 hover:text-ink text-2xl leading-none"
                >
                  &times;
                </button>
              </div>
            </div>
            <div class="p-6 space-y-4">
              <%= if @selected.dbs_offence do %>
                <div class="border-2 border-dark bg-well rounded-xl p-4">
                  <div class="text-xs uppercase tracking-wider font-bold text-orange">
                    Disclosure on file
                  </div>
                  <div class="text-sm text-ink mt-1">{@selected.dbs_offence}</div>
                </div>
              <% end %>

              <div>
                <div class="text-xs uppercase tracking-wider text-muted">Pitch</div>
                <div class="mt-1 italic">"{@selected.pitch}"</div>
              </div>

              <%= if @selected.score do %>
                <div class="bg-well border border-line rounded-xl p-4">
                  <div class="flex items-center gap-2">
                    <img
                      src={reviewer_avatar(:hr_screen)}
                      alt={reviewer_alt(:hr_screen)}
                      class="w-10 h-10 rounded-full object-cover"
                    />
                    <div class="text-xs uppercase tracking-wider text-muted">
                      Janine's score
                    </div>
                  </div>
                  <div class="flex items-baseline gap-2 mt-1">
                    <div class="text-4xl font-black">
                      {@selected.score}<span class="text-lg text-muted">/10</span>
                    </div>
                    <div class="text-sm text-muted italic">"{@selected.score_reason}"</div>
                  </div>
                </div>
              <% end %>

              <%= if @selected.lead_score do %>
                <div class="bg-well border border-line rounded-xl p-4">
                  <div class="flex items-center gap-2">
                    <img
                      src={reviewer_avatar(:lead_interview)}
                      alt={reviewer_alt(:lead_interview)}
                      class="w-10 h-10 rounded-full object-cover"
                    />
                    <div class="text-xs uppercase tracking-wider text-muted">
                      Steve's score
                    </div>
                  </div>
                  <div class="flex items-baseline gap-2 mt-1">
                    <div class="text-4xl font-black">
                      {@selected.lead_score}<span class="text-lg text-muted">/10</span>
                    </div>
                    <div class="text-sm text-muted italic">"{@selected.lead_note}"</div>
                  </div>
                </div>
              <% end %>

              <%= if @selected.dbs_reference do %>
                <div class="text-xs text-muted">
                  DBS reference <span class="font-mono text-ink">{@selected.dbs_reference}</span>
                </div>
              <% end %>

              <%= if waiting_on(@selected.state) do %>
                <% {timeout, who} = waiting_on(@selected.state) %>
                <div class="bg-well border border-line rounded-xl p-4 text-center">
                  <div class="text-xs uppercase tracking-wider text-muted">{who}</div>
                  <div class="text-3xl font-black text-ink">
                    {Deadlines.seconds_until(Deadlines.due_at(@selected, timeout), @now)}s
                  </div>
                </div>
              <% end %>

              <div class="text-xs text-muted">
                Submitted {Calendar.strftime(@selected.inserted_at, "%H:%M:%S")} &middot; In state since {Calendar.strftime(
                  @selected.state_entered_at,
                  "%H:%M:%S"
                )}
              </div>

              <%= if @selected.state == :final_approval do %>
                <div class="flex gap-2 pt-2">
                  <button
                    phx-click="offer"
                    phx-value-id={@selected.id}
                    class="flex-1 bg-green hover:bg-green/85 text-ink font-bold py-3 rounded-lg"
                  >
                    Make the offer
                  </button>
                  <button
                    phx-click="veto"
                    phx-value-id={@selected.id}
                    class="flex-1 bg-dark hover:bg-dark/85 text-cream font-bold py-3 rounded-lg"
                  >
                    Veto
                  </button>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @maximised do %>
        <% char = character(@maximised) %>
        <div
          phx-window-keydown="close_maximised"
          phx-key="Escape"
          class="fixed inset-0 bg-ink/80 backdrop-blur-sm z-50 overflow-y-auto"
        >
          <div phx-click-away="close_maximised" class="min-h-full text-cream p-10 max-w-6xl mx-auto">
            <div class="flex justify-end">
              <button
                phx-click="close_maximised"
                class="text-cream/80 hover:text-cream text-4xl leading-none"
              >
                &times;
              </button>
            </div>

            <div class="flex items-center gap-8 mb-10">
              <%= if character_portrait(@maximised) do %>
                <img
                  src={character_portrait(@maximised)}
                  alt={char.alt}
                  class={
                    "w-80 h-80 shrink-0 rounded-full ring-8 ring-amber " <>
                      if(@maximised == :background_check,
                        do: "object-contain bg-well p-8",
                        else: "object-contain object-bottom bg-cream"
                      )
                  }
                />
              <% else %>
                <%!-- :hired and :rejected have no face to show, so the panel
                      takes the column's icon at full size instead of a gap. It
                      keeps the portraits' cream disc: :rejected's hue is the
                      same near-black as this overlay and would vanish on it. --%>
                <div class="w-80 h-80 shrink-0 flex items-center justify-center rounded-full bg-cream ring-8 ring-amber">
                  <span
                    :if={column_icon(@maximised)}
                    class={column_icon(@maximised) <> " w-56 h-56"}
                    style={"color: #{Palette.hex(@maximised)}"}
                  >
                  </span>
                </div>
              <% end %>
              <div class="min-w-0">
                <h2 class="font-serif text-7xl font-black">{char.name}</h2>
                <div class="text-2xl uppercase tracking-widest text-cream/60 mt-2">
                  {char.role}
                </div>
                <p class="text-2xl text-cream mt-6 max-w-3xl">{char.bio}</p>
              </div>
            </div>

            <%= if Map.get(@by_state, @maximised, []) == [] do %>
              <div class="text-3xl text-cream/60 italic text-center py-20">{char.empty}</div>
            <% else %>
              <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-6">
                <%= for c <- Map.get(@by_state, @maximised, []) do %>
                  <.candidate_card c={c} state={@maximised} now={@now} />
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @qr_maximised && @tunnel_url do %>
        <div
          phx-window-keydown="close_maximised_qr"
          phx-key="Escape"
          class="fixed inset-0 bg-ink/80 backdrop-blur-sm z-50 flex items-center justify-center p-6"
        >
          <div
            phx-click-away="close_maximised_qr"
            class="bg-white rounded-2xl shadow-2xl p-10 flex flex-col items-center gap-6 relative"
          >
            <button
              phx-click="close_maximised_qr"
              class="absolute top-4 right-4 text-muted hover:text-ink text-3xl leading-none"
            >
              &times;
            </button>
            {qr_svg(@tunnel_url <> "/apply", 700)}
            <div class="text-2xl font-mono text-ink">{@tunnel_url}/apply</div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :c, :map, required: true
  attr :state, :atom, required: true
  attr :now, :any, required: true

  defp candidate_card(assigns) do
    ~H"""
    <div
      phx-click="open_card"
      phx-value-id={@c.id}
      class="bg-well border border-line rounded-lg overflow-hidden shadow cursor-pointer hover:border-muted/50 hover:-translate-y-0.5 transition"
    >
      <%= if @c.dbs_offence do %>
        <div class="bg-dark text-cream text-xs font-bold px-3 py-2">
          ⚠️ {@c.dbs_offence}
        </div>
      <% end %>

      <div class="p-3">
        <div class="flex items-center gap-3">
          <img
            src={@c.avatar_url}
            alt={"#{@c.name}'s avatar"}
            class="w-12 h-12 rounded-full bg-paper shrink-0"
          />
          <div class="min-w-0 flex-1">
            <div class="font-bold text-sm truncate">{@c.name}</div>
            <%= if @c.score do %>
              <div class="text-xs text-muted">Janine: {@c.score}/10</div>
            <% end %>
            <%= if @c.lead_score do %>
              <div class="text-xs text-muted">Steve: {@c.lead_score}/10</div>
            <% end %>
          </div>
        </div>
        <div class="text-xs text-muted mt-2 italic line-clamp-2">"{@c.pitch}"</div>

        <%= if @state == :hr_screen do %>
          <div class="text-xs text-orange font-bold mt-2">
            Waiting on Janine &middot; {Deadlines.seconds_until(
              Deadlines.due_at(@c, :janine_responds),
              @now
            )}s left
          </div>
        <% end %>

        <%= if @state == :background_check do %>
          <div class="text-xs font-mono text-muted mt-2">{@c.dbs_reference}</div>
          <div class="text-xs text-orange font-bold mt-1">
            {Deadlines.seconds_until(Deadlines.due_at(@c, :bureau_responds), @now)}s left
          </div>
        <% end %>

        <%= if @state == :lead_interview do %>
          <div class="text-xs text-orange font-bold mt-2">
            Waiting on Steve &middot; {Deadlines.seconds_until(
              Deadlines.due_at(@c, :steve_responds),
              @now
            )}s left
          </div>
        <% end %>

        <%= if @state == :final_approval do %>
          <div class="text-xs text-orange font-bold mt-2">
            {Deadlines.seconds_until(Deadlines.due_at(@c, :jefe_no_answer), @now)}s left
          </div>
          <div class="flex gap-1 mt-2">
            <button
              phx-click="offer"
              phx-value-id={@c.id}
              class="flex-1 bg-green hover:bg-green/85 text-ink text-xs font-bold py-1.5 rounded"
            >
              Make the offer
            </button>
            <button
              phx-click="veto"
              phx-value-id={@c.id}
              class="flex-1 bg-dark hover:bg-dark/85 text-cream text-xs font-bold py-1.5 rounded"
            >
              Veto
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
