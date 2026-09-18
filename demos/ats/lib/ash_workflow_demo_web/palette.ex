defmodule AshWorkflowDemoWeb.Palette do
  @moduledoc """
  The per-step hues and labels every page shares.

  The base tokens (`ink`, `paper`, `accent`, `bubble`) live in
  `assets/tailwind.config.js` and are kept in step with the talk deck's
  `slides/theme/alembic.css`. The step hues live here because three pages
  need them in two forms: a Tailwind class for a band or a chip, and a raw
  hex for an inline rule or heading colour.

  `:hr_decision`, `:bureau_result` and `:lead_decision` share their hue with
  the wait step before them. Those steps are instantaneous, so a candidate
  passing through one should not make the board flicker a different colour.
  """

  @steps %{
    hr_screen: {"#f59e0b", "HR screen"},
    hr_decision: {"#f59e0b", "HR screen"},
    background_check: {"#a855f7", "DBS check"},
    bureau_result: {"#a855f7", "DBS check"},
    lead_interview: {"#6366f1", "Lead interview"},
    lead_decision: {"#6366f1", "Lead interview"},
    final_approval: {"#14b8a6", "El Jefe"},
    hired: {"#10b981", "Hired"},
    rejected: {"#f43f5e", "Rejected"}
  }

  @unknown {"#9aa4b2", "—"}

  @doc "The step's hex, for an inline `style` on a rule, heading or band."
  def hex(step), do: @steps |> Map.get(step, @unknown) |> elem(0)

  @doc "What a human calls the step."
  def label(nil), do: "—"
  def label(step), do: @steps |> Map.get(step, @unknown) |> elem(1)

  @doc "Every step that has its own hue, for a legend."
  def steps, do: Map.keys(@steps)
end
