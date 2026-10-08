defmodule AshWorkflow.Transformers.AddCalculations do
  @moduledoc """
  Generates workflow calculations on the resource.

  Adds the following calculations (using `add_new_calculation` so user-defined
  calculations take precedence):

  - `:available_actions` — list of user-facing transition names for the current step
  - `:transition_targets` — map of each transition of the current step to the
    step it would move the record to
  - `:steps` — list of all workflow step names (static, same for every record)
  - `:current_step` — the name of the workflow's current step
  - `:pending_deadlines` — the timeouts ahead of the record in its current step
  - `:workflow_terminated_at` — when the record entered a terminal step, or nil
    while the workflow is still running. The `terminated_at_calculation` option
    renames it
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
  alias Spark.Dsl.Transformer

  require Ash.Expr

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

    terminated_at_calculation =
      Transformer.get_option(
        dsl,
        [:workflow],
        :terminated_at_calculation,
        :workflow_terminated_at
      )

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
             :transition_targets,
             :map,
             {AshWorkflow.Calculations.TransitionTargets,
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
      Builder.add_new_calculation(
        dsl,
        terminated_at_calculation,
        :utc_datetime_usec,
        terminated_at_expr(steps, state_attribute),
        public?: true
      )
    end
  end

  # A terminal step has no outgoing transitions, so the instant the record
  # entered it is the instant the workflow ended. An expression keeps it
  # filterable and sortable in the data layer.
  defp terminated_at_expr(steps, state_attribute) do
    terminal_steps = steps |> Enum.filter(&Step.terminal?/1) |> Enum.map(& &1.name)

    Ash.Expr.expr(
      if ^Ash.Expr.ref(state_attribute) in ^terminal_steps do
        state_entered_at
      else
        nil
      end
    )
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

  def after?(AshWorkflow.Transformers.AddCodeInterface), do: true
  def after?(_), do: false
end
