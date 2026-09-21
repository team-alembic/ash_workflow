defmodule AshWorkflow.Calculations.EnteredCurrentStateAt do
  @moduledoc """
  Ash calculation that returns the `occurred_at` of the most recent transition
  log row where `from_state != to_state`.

  An `every` writes a row with `from_state == to_state` to log its firing
  without it being a state change, and this calculation filters those out.
  Only registered when a `transition_log` is configured; see
  `AshWorkflow.Transformers.AddCalculations`.
  """
  use Ash.Resource.Calculation

  alias AshWorkflow.TransitionLog

  @impl true
  @spec load(Ash.Query.t(), Keyword.t(), map()) :: []
  def load(_query, _opts, _context), do: []

  @impl true
  @spec calculate([Ash.Resource.record()], Keyword.t(), map()) :: [DateTime.t() | nil]
  def calculate(records, _opts, _context) do
    Enum.map(records, &entered_current_state_at/1)
  end

  defp entered_current_state_at(record) do
    record
    |> TransitionLog.history()
    |> Enum.filter(&(&1.from_state != &1.to_state))
    |> Enum.max_by(& &1.occurred_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      row -> row.occurred_at
    end
  end
end
