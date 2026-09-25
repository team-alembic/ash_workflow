defmodule AshWorkflow.Charts.Format do
  @moduledoc false

  # Writes DSL values out as the short phrases a chart shows. Every backend
  # reads its labels from `AshWorkflow.Charts.Graph`, which calls these, so
  # Mermaid, JSON and any later backend use the same words.

  alias AshWorkflow.Entities.Retry

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
      module.describe(opts)
    else
      inspect({module, opts})
    end
  end

  def policy(module) when is_atom(module), do: policy({module, []})
  def policy(other), do: inspect(other)

  @doc """
  A route's `when` expression, or `nil` for a route without one.
  """
  @spec condition(term()) :: String.t() | nil
  def condition(nil), do: nil
  def condition(expression), do: inspect(expression)
end
