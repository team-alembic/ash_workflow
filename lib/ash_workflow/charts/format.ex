defmodule AshWorkflow.Charts.Format do
  @moduledoc """
  Writes DSL values out as the short phrases a chart shows.

  Every backend reads its labels from `AshWorkflow.Charts.Graph`, which calls
  these functions, so Mermaid, JSON and a custom `AshWorkflow.Charts.Backend`
  all use the same words.
  """

  alias AshWorkflow.Entities.Retry
  alias AshWorkflow.Entities.Undo

  @doc """
  A duration tuple as text, in the singular for one unit: `{1, :days}` is
  "1 day" and `{7, :days}` is "7 days".
  """
  @spec duration(AshWorkflow.Duration.t()) :: String.t()
  def duration({1, unit}), do: "1 #{singular(unit)}"
  def duration({value, unit}), do: "#{value} #{unit}"

  defp singular(:seconds), do: "second"
  defp singular(:minutes), do: "minute"
  defp singular(:hours), do: "hour"
  defp singular(:days), do: "day"

  @doc """
  The deadline of a timeout entry from `AshWorkflow.Info.workflow_graph/1`.
  """
  @spec deadline(map()) :: String.t()
  def deadline(%{fire_at: field}) when not is_nil(field), do: "at #{field}"

  def deadline(%{fire_after: duration, field: field}) when field in [nil, :state_entered_at],
    do: "after #{duration(duration)}"

  def deadline(%{fire_after: duration, field: field}),
    do: "#{duration(duration)} after #{field}"

  @doc """
  The schedule of an `every` entry from `AshWorkflow.Info.workflow_graph/1`.
  """
  @spec every(map()) :: String.t()
  def every(%{interval: interval, until: nil}), do: "every #{duration(interval)}"

  def every(%{interval: interval, until: until}),
    do: "every #{duration(interval)} for #{duration(until)}"

  @doc """
  The label of an undo edge, with the window when the `undo` block sets
  `within`: "undo" or "undo within 1 hour".
  """
  @spec undo(Undo.t()) :: String.t()
  def undo(%Undo{within: nil}), do: "undo"
  def undo(%Undo{within: within}), do: "undo within #{duration(within)}"

  @doc """
  The retry policy of a step, or `nil` when the step makes one attempt only.
  """
  @spec retry(Retry.t() | nil) :: String.t() | nil
  def retry(nil), do: nil
  def retry(%Retry{max_attempts: 1}), do: nil

  def retry(%Retry{max_attempts: attempts, backoff: :exponential}),
    do: "#{attempts} attempts, exponential backoff"

  def retry(%Retry{max_attempts: attempts, backoff: backoff}),
    do: "#{attempts} attempts, #{duration(backoff)} apart"

  @doc """
  A step's `policy` check, through the check's own `describe/1` when it has one.
  """
  @spec policy(term()) :: String.t() | nil
  def policy(nil), do: nil

  def policy({module, opts}) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :describe, 1) do
      templates(module.describe(opts))
    else
      inspect({module, opts})
    end
  end

  def policy(module) when is_atom(module), do: policy({module, []})
  def policy(other), do: templates(inspect(other))

  @doc """
  A route's `when` expression, or `nil` for a route without one.
  """
  @spec condition(term()) :: String.t() | nil
  def condition(nil), do: nil
  def condition(expression), do: templates(inspect(expression))

  # Ash stores `^actor(:role)` as the tuple `{:_actor, :role}` and `^tenant()`
  # as the atom `:_tenant`, and `inspect/1` writes those. Write them as the
  # templates the DSL shows. `^arg(...)` and `^context(...)` work as `^actor`.
  defp templates(text) do
    text
    |> String.replace(~r/\{:_(actor|arg|context), ([^{}]+?)\}/, "^\\1(\\2)")
    |> String.replace(~r/:_tenant\b/, "^tenant()")
  end
end
