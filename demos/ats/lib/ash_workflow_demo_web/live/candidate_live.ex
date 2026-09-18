defmodule AshWorkflowDemoWeb.CandidateLive do
  @moduledoc """
  The candidate's own view of where they are, sized to sit on one projected
  slide without scrolling.

  The three people who judge a candidate read left to right in one row:
  Janine, then Steve, then El Jefe. A reviewer who has not answered yet holds
  their column rather than collapsing it, so the row keeps its shape as the
  candidate moves and the audience is not watching cards jump about.

  El Jefe's column comes from the transition log rather than from `state`.
  `:rejected` alone cannot say whether El Jefe vetoed the candidate, whether
  the cascade beat them to the slot, or whether they never reached him at
  all — only the row leaving `:final_approval` knows.
  """

  use AshWorkflowDemoWeb, :live_view

  alias AshWorkflowDemo.ATS.Candidate
  alias AshWorkflowDemoWeb.Palette

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AshWorkflowDemo.PubSub, "candidates:#{id}")
    end

    case AshWorkflowDemo.ATS.get_candidate(id) do
      {:ok, c} -> {:ok, assign(socket, candidate: c)}
      _ -> {:ok, socket |> put_flash(:error, "Not found") |> push_navigate(to: "/apply")}
    end
  end

  @impl true
  def handle_info({:candidate_changed, id}, socket) do
    {:ok, c} = AshWorkflowDemo.ATS.get_candidate(id)
    {:noreply, assign(socket, candidate: c)}
  end

  defp state_copy(state) when state in [:hr_screen, :hr_decision],
    do: {"HR screen", "Janine is reading your pitch."}

  defp state_copy(state) when state in [:background_check, :bureau_result],
    do: {"Background check", "The bureau is running your history. Try not to think about it."}

  defp state_copy(state) when state in [:lead_interview, :lead_decision],
    do: {"Lead interview", "Steve is deciding whether you're the one."}

  defp state_copy(:final_approval), do: {"El Jefe is deciding", "It's his call now."}
  defp state_copy(:hired), do: {"¡HIRED!", "You are El Jefe's new hire. Felicidades."}
  defp state_copy(:rejected), do: {"Rejected", "No dice. Better luck next time."}
  defp state_copy(_), do: {"—", ""}

  defp stage_label(state) when state in [:hr_screen, :hr_decision], do: "Stage 1 of 4"
  defp stage_label(state) when state in [:background_check, :bureau_result], do: "Stage 2 of 4"
  defp stage_label(state) when state in [:lead_interview, :lead_decision], do: "Stage 3 of 4"
  defp stage_label(:final_approval), do: "Stage 4 of 4"
  defp stage_label(:hired), do: "Hired"
  defp stage_label(:rejected), do: "Closed"
  defp stage_label(_), do: "—"

  defp janine_column(%{score: score, score_reason: reason}) when not is_nil(score) do
    %{value: "#{score}/10", note: reason, tone: if(score >= 4, do: :good, else: :bad)}
  end

  defp janine_column(_candidate),
    do: %{value: "—", note: "Reading your pitch.", tone: :pending}

  defp steve_column(%{lead_score: score, lead_note: note}) when not is_nil(score) do
    %{value: "#{score}/10", note: note, tone: if(score >= 4, do: :good, else: :bad)}
  end

  defp steve_column(candidate) do
    if reached?(candidate, :lead_interview) do
      %{value: "—", note: "Writing up the interview.", tone: :pending}
    else
      %{value: "—", note: "Never got this far.", tone: :never}
    end
  end

  # El Jefe's column is always on the page and stays grey until he has
  # actually answered. Only `:offer` and `:veto` are his answer: `:slot_taken`
  # is the cascade off somebody else's offer, and a candidate at
  # `:final_approval` is still waiting on him.
  #
  # `:rejected` on its own cannot tell these apart. The row that left
  # `:final_approval` can, which is why this reads the log rather than `state`.
  defp jefe_column(%{state: :final_approval}),
    do: %{value: "Deciding", note: "The only two buttons on the board.", tone: :pending}

  defp jefe_column(candidate) do
    case Enum.find(Candidate.history(candidate), &(&1.from_state == :final_approval)) do
      %{transition_name: :offer} ->
        %{value: "Offer", note: "He picked you.", tone: :good}

      %{transition_name: :veto} ->
        %{value: "Veto", note: "He turned you down himself.", tone: :bad}

      %{transition_name: :slot_taken} ->
        %{value: "Too late", note: "Somebody else took the slot.", tone: :never}

      _ ->
        %{value: "—", note: "Never reached his desk.", tone: :never}
    end
  end

  defp reached?(candidate, state) do
    Enum.any?(Candidate.history(candidate), &(&1.to_state == state))
  end

  defp tone_color(:good), do: "#10b981"
  defp tone_color(:bad), do: "#f43f5e"
  defp tone_color(:pending), do: "#9aa4b2"
  defp tone_color(:never), do: "#4b5563"

  # A card only comes up to full strength once its reviewer has answered.
  # Everything else is a column holding its place.
  defp answered?(tone), do: tone in [:good, :bad]

  defp panel_class(tone) do
    if answered?(tone),
      do: "border-ink-line bg-ink-raised",
      else: "border-ink-line/50 bg-ink-raised/40"
  end

  defp portrait_class(:never), do: "opacity-25 grayscale"
  defp portrait_class(tone), do: if(answered?(tone), do: "", else: "opacity-60")

  attr :portrait, :string, required: true
  attr :who, :string, required: true
  attr :column, :map, required: true

  defp verdict_card(assigns) do
    ~H"""
    <div class={
      "flex min-h-0 flex-col items-center rounded-2xl border px-[1vw] py-[1.6vh] text-center " <>
        panel_class(@column.tone)
    }>
      <div class="flex shrink-0 items-center gap-[0.5vw]">
        <img
          src={@portrait}
          alt={@who}
          class={
            "h-[4.4vh] w-[4.4vh] rounded-full object-cover object-top bg-paper/10 " <>
              portrait_class(@column.tone)
          }
        />
        <span class="text-[clamp(0.6rem,1.5vh,0.95rem)] font-bold uppercase tracking-[0.12em] text-paper-muted">
          {@who}
        </span>
      </div>

      <div
        class="mt-[0.8vh] shrink-0 font-black leading-none text-[clamp(1.6rem,6vh,4.5rem)]"
        style={"color: #{tone_color(@column.tone)}"}
      >
        {@column.value}
      </div>

      <p class="mt-[0.8vh] min-h-0 overflow-hidden text-[clamp(0.7rem,1.7vh,1.05rem)] italic leading-snug text-paper-muted">
        {@column.note}
      </p>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    {heading, sub} = state_copy(assigns.candidate.state)

    assigns =
      assign(assigns,
        heading: heading,
        sub: sub,
        accent: Palette.hex(assigns.candidate.state),
        stage: stage_label(assigns.candidate.state),
        janine: janine_column(assigns.candidate),
        steve: steve_column(assigns.candidate),
        jefe: jefe_column(assigns.candidate)
      )

    ~H"""
    <div class="flex h-screen w-screen flex-col overflow-hidden bg-ink px-[3.5vw] py-[3vh] text-paper">
      <header class="flex shrink-0 items-center gap-[1.4vw]">
        <img
          src={@candidate.avatar_url}
          alt={@candidate.name}
          class="h-[9vh] w-[9vh] shrink-0 rounded-full bg-paper p-[0.5vh] shadow-2xl"
        />
        <div class="min-w-0 flex-1">
          <h1 class="truncate text-[clamp(1.4rem,3.6vh,3rem)] font-black leading-tight">
            {@candidate.name}
          </h1>
          <p class="truncate text-[clamp(0.65rem,1.6vh,1rem)] italic text-paper-muted">
            "{@candidate.pitch}"
          </p>
        </div>
        <span
          class="shrink-0 rounded-full px-[1.1vw] py-[0.7vh] text-[clamp(0.6rem,1.5vh,0.95rem)] font-bold uppercase tracking-[0.12em] text-ink"
          style={"background: #{@accent}"}
        >
          {@stage}
        </span>
      </header>

      <div class="mt-[1.6vh] h-[0.5vh] shrink-0 rounded-full" style={"background: #{@accent}"}></div>

      <section class="mt-[1.8vh] flex shrink-0 items-baseline gap-[1.4vw]">
        <h2
          class="font-black uppercase leading-none tracking-tight text-[clamp(2rem,8vh,6rem)]"
          style={"color: #{@accent}"}
        >
          {@heading}
        </h2>
        <p class="min-w-0 flex-1 text-[clamp(0.8rem,2vh,1.3rem)] leading-snug text-paper-muted">
          {@sub}
        </p>
        <div :if={@candidate.state == :hired} class="shrink-0 animate-bounce text-[6vh]">🎉</div>
      </section>

      <div
        :if={@candidate.dbs_offence}
        class="mt-[1.8vh] flex shrink-0 items-center gap-[1.2vw] rounded-2xl border-4 border-black bg-bubble px-[1.4vw] py-[1.4vh] text-bubble-ink"
      >
        <span class="shrink-0 text-[clamp(0.6rem,1.5vh,0.95rem)] font-bold uppercase tracking-[0.1em] text-bubble-who">
          ⚠️ Disclosure on file
        </span>
        <span class="min-w-0 flex-1 text-[clamp(0.8rem,2.1vh,1.35rem)] font-bold leading-snug">
          {@candidate.dbs_offence}
        </span>
        <span class="shrink-0 text-[clamp(0.6rem,1.4vh,0.9rem)] opacity-70">
          Nobody's judging you for this one.
        </span>
      </div>

      <div class="mt-[2vh] grid min-h-0 flex-1 grid-cols-3 gap-[1.4vw]">
        <.verdict_card portrait="/images/janine-hr.png" who="Janine" column={@janine} />
        <.verdict_card portrait="/images/steve-tech.png" who="Steve" column={@steve} />
        <.verdict_card portrait="/images/conor.png" who="El Jefe" column={@jefe} />
      </div>
    </div>
    """
  end
end
