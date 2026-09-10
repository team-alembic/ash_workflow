defmodule AshWorkflowDemo.ATS.Candidate.Deadlines do
  @moduledoc """
  Reads the candidate workflow's deadlines out of the DSL, so the interface
  never states a duration the scheduler is not using.

  Two questions, two answers.

  `seconds/1` answers "how long is this timeout", from the DSL. Static copy
  wants it: "El Jefe has 30 seconds to decide" should say 30 because the DSL
  says `after: {30, :seconds}`, not because someone typed 30 into a heredoc.

  `due_at/2` answers "when does this record's deadline fall", from the record's
  `pending_deadlines` calculation. A live countdown wants that, because the
  answer differs per candidate and it is the instant
  `AshWorkflow.Scheduler.Precise` armed its timer for.
  """

  alias AshWorkflowDemo.ATS.Candidate

  @doc """
  The declared duration of a timeout, in seconds.

  Resolved at compile time from the workflow DSL, so changing
  `after: {30, :seconds}` changes every place that quotes it.
  """
  @spec seconds(atom()) :: pos_integer()
  def seconds(timeout_name) do
    Candidate
    |> AshWorkflow.Info.steps()
    |> Enum.flat_map(& &1.timeouts)
    |> Enum.find(&(&1.name == timeout_name))
    |> case do
      nil -> raise ArgumentError, "no timeout named #{inspect(timeout_name)} on #{Candidate}"
      timeout -> in_seconds(timeout.after)
    end
  end

  @doc """
  When a record's pending deadline falls, or `nil` if it has none.

  Requires `pending_deadlines` to be loaded. The list only holds deadlines
  ahead of the record in the step it currently occupies, so a candidate that
  has left `:review` has no `:auto_reject` entry and the countdown stops.
  """
  @spec due_at(Ash.Resource.record(), atom()) :: DateTime.t() | nil
  def due_at(%{pending_deadlines: deadlines}, timeout_name) when is_list(deadlines) do
    case Enum.find(deadlines, &(&1.name == timeout_name)) do
      nil -> nil
      deadline -> deadline.due_at
    end
  end

  def due_at(_record, _timeout_name), do: nil

  @doc """
  Whole seconds from `now` until the deadline, rounded up, floored at zero.

  Rounded up so the countdown reads zero only once the deadline has actually
  passed, which is the instant `AshWorkflow.Scheduler.Precise` fires. Rounding
  down shows "0s left" for the whole second before the transition, and the card
  sits at zero while nothing happens.
  """
  @spec seconds_until(DateTime.t() | nil, DateTime.t()) :: non_neg_integer()
  def seconds_until(nil, _now), do: 0

  def seconds_until(due_at, now) do
    case DateTime.diff(due_at, now, :millisecond) do
      remaining when remaining <= 0 -> 0
      remaining -> div(remaining + 999, 1_000)
    end
  end

  defp in_seconds({value, :seconds}), do: value
  defp in_seconds({value, :minutes}), do: value * 60
  defp in_seconds({value, :hours}), do: value * 3_600
  defp in_seconds({value, :days}), do: value * 86_400
end
