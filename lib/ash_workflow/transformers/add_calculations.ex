defmodule AshWorkflow.Transformers.AddCalculations do
  @moduledoc """
  Generates workflow calculations on the resource.

  Adds the following calculations (using `add_new_calculation` so user-defined
  calculations take precedence):

  - `:available_actions` — list of user-facing transition names for the current step
  - `:steps` — list of all workflow step names (static, same for every record)
  - `:current_step` — the name of the workflow's current step
  - `:pending_deadlines` — the timeouts ahead of the record in its current step
  - `:entered_current_state_at` — only when a `transition_log` is configured
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    steps =
      dsl
      |> Transformer.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    steps_map =
      steps
      |> Enum.filter(&Step.manual?/1)
      |> Map.new(fn step ->
        {step.name, Enum.map(step.transitions, & &1.name)}
      end)

    step_names = Enum.map(steps, & &1.name)
    state_attribute = AshWorkflow.Info.state_attribute(dsl)

    with {:ok, dsl} <-
           Builder.add_new_calculation(
             dsl,
             :available_actions,
             {:array, :atom},
             {AshWorkflow.Calculations.AvailableActions,
              steps_map: steps_map, state_attribute: state_attribute},
             public?: true
           ),
         {:ok, dsl} <-
           Builder.add_new_calculation(
             dsl,
             :steps,
             {:array, :atom},
             {AshWorkflow.Calculations.Steps, step_names: step_names},
             public?: true
           ),
         {:ok, dsl} <-
           Builder.add_new_calculation(
             dsl,
             :current_step,
             :atom,
             {AshWorkflow.Calculations.CurrentStep, state_attribute: state_attribute},
             public?: true
           ),
         {:ok, dsl} <-
           Builder.add_new_calculation(
             dsl,
             :pending_deadlines,
             {:array, :map},
             {AshWorkflow.Calculations.PendingDeadlines,
              timeouts: timeouts_map(steps), state_attribute: state_attribute},
             public?: true
           ) do
      add_entered_current_state_at(dsl)
    end
  end

  # Flattened at compile time so the calculation does no DSL introspection per
  # record. Terminal steps are excluded: a record there has no deadlines ahead.
  defp timeouts_map(steps) do
    steps
    |> Enum.reject(&(Step.terminal?(&1) or (&1.timeouts == [] and &1.everys == [])))
    |> Map.new(fn step ->
      {step.name,
       Enum.map(step.timeouts, &timeout_entry/1) ++
         Enum.map(step.everys, &every_entry(step, &1))}
    end)
  end

  defp timeout_entry(timeout) do
    %{
      name: timeout.name,
      field: Timeout.deadline_field(timeout),
      fire_after: timeout.fire_after,
      kind: if(timeout.transition_to, do: :transition, else: :action),
      target: timeout.transition_to
    }
  end

  # An `every` writes its own last-fired column on every fire, so unlike a
  # non-repeating action timeout its `due_at` never goes stale: it is always
  # the next instant the action will run. A record that has never fired has a
  # nil column, and `AshWorkflow.Calculations.PendingDeadlines` measures from
  # `state_entered_at` for it, rather than omitting it the way it omits any
  # other nil `field`.
  defp every_entry(step, every) do
    %{
      name: every.name,
      field: Every.last_fired_field(step.name, every),
      fire_after: every.interval,
      kind: :every,
      target: nil
    }
  end

  defp add_entered_current_state_at(dsl) do
    case AshWorkflow.Info.transition_log(dsl) do
      nil ->
        {:ok, dsl}

      _log ->
        Builder.add_new_calculation(
          dsl,
          :entered_current_state_at,
          :utc_datetime_usec,
          AshWorkflow.Calculations.EnteredCurrentStateAt,
          public?: true
        )
    end
  end

  def after?(AshWorkflow.Transformers.AddCodeInterface), do: true
  def after?(_), do: false
end
