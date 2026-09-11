defmodule AshWorkflow.Verifiers.ValidateRetry do
  @moduledoc """
  Rejects a `retry` block declared on a step nothing is scheduled for.

  A manual step, a wait state, and a terminal step none have a generated
  trigger to retry — `AshWorkflow.Transformers.AddScheduler` only turns an
  automatic step into a `AshWorkflow.Scheduler.Work`, through
  `AshWorkflow.Entities.Step.manual?/1` and the `terminal` flag. A `retry`
  block on one of these compiles but does nothing, so it is rejected instead.
  """
  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    dsl
    |> Verifier.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
    |> Enum.reduce_while(:ok, fn step, :ok ->
      case validate(step) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate(%Step{retry: nil}), do: :ok

  defp validate(%Step{terminal: true} = step) do
    {:error,
     DslError.exception(
       path: [:workflow, :step, step.name, :retry],
       message: """
       Step :#{step.name} declares a retry block, but it is terminal. A \
       terminal step has no action for the scheduler to run, so there is \
       nothing to retry. Remove the retry block.
       """
     )}
  end

  defp validate(%Step{} = step) do
    if Step.manual?(step) do
      {:error,
       DslError.exception(
         path: [:workflow, :step, step.name, :retry],
         message: """
         Step :#{step.name} declares a retry block, but it is a manual step \
         or a wait state. Nothing is scheduled for it, so the retry block \
         would do nothing. Remove the retry block, or give the step an \
         `action` so it has something for the scheduler to retry.
         """
       )}
    else
      :ok
    end
  end
end
