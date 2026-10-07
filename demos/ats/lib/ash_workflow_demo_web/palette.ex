defmodule AshWorkflowDemoWeb.Palette do
  @moduledoc """
  The per-step hues and labels every page shares.

  The base tokens (`cream`, `ink`, `paper`, `amber`, ...) live in
  `assets/tailwind.config.js` and are kept in step with the talk deck's
  `slides/2026-ashconf-when-time-meets-state/onlysands.css`. The step hues live here
  because three pages need them in two forms: a Tailwind class for a band or
  a chip, and a raw hex for an inline rule or heading colour.

  HR screen, lead interview and El Jefe reuse the colours behind Janine,
  Steve and the Big Boss on their slides. The deck carries no red, so
  `:rejected` borrows the deck's one dark section colour instead of
  inventing an off-brand one.

  `:hr_decision`, `:bureau_result` and `:lead_decision` share their hue with
  the wait step before them. Those steps are instantaneous, so a candidate
  passing through one should not make the board flicker a different colour.
  """

  @steps %{
    hr_screen: {"#c95b05", "HR screen"},
    hr_decision: {"#c95b05", "HR screen"},
    background_check: {"#8a7864", "DBS check"},
    bureau_result: {"#8a7864", "DBS check"},
    lead_interview: {"#8fa1ff", "Lead interview"},
    lead_decision: {"#8fa1ff", "Lead interview"},
    final_approval: {"#3ba181", "El Jefe"},
    hired: {"#f2b540", "Hired"},
    rejected: {"#100d18", "Rejected"}
  }

  @unknown {"#9c9484", "—"}

  @doc "The step's hex, for an inline `style` on a rule, heading or band."
  def hex(step), do: @steps |> Map.get(step, @unknown) |> elem(0)

  @doc "What a human calls the step."
  def label(nil), do: "—"
  def label(step), do: @steps |> Map.get(step, @unknown) |> elem(1)

  @doc "Every step that has its own hue, for a legend."
  def steps, do: Map.keys(@steps)
end
