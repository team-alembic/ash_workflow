defmodule AshWorkflow.Transformers.AddStateMachine do
  @moduledoc """
  Generates ash_state_machine configuration from workflow steps.

  Injects the following into the resource's `state_machine` DSL:

  - **`initial_states`** — set to the first non-terminal step by declaration order.
    In future, an `initial: true` flag on step may allow explicit override.
  - **`default_initial_state`** — same as above
  - **Transitions** for each step type:
    - *Automatic steps* — `transition :step_action, from: [:step_name], to: [:on_success]`.
      If `on_error` is set, an additional transition to the error state is added.
    - *Manual steps* — one transition per declared `transition` entity,
      e.g. `transition :approve, from: [:review], to: [:approved]`
    - *Timeouts with `transition_to`* — a transition named `__timeout_<name>`,
      e.g. `transition :__timeout_escalation, from: [:review], to: [:escalated]`

  Must run before all `AshStateMachine.Transformers.*` so that the state machine
  extension sees the generated states and transitions.
  """
  use Spark.Dsl.Transformer

  alias AshWorkflow.Entities.Transition
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    steps = Transformer.get_entities(dsl, [:workflow])
    first_step = steps |> Enum.reject(& &1.terminal) |> List.first()

    dsl =
      dsl
      |> Transformer.set_option([:state_machine], :initial_states, [first_step.name])
      |> Transformer.set_option([:state_machine], :default_initial_state, first_step.name)

    transitions = build_transitions(steps)

    dsl =
      Enum.reduce(transitions, dsl, fn transition, dsl ->
        Transformer.add_entity(dsl, [:state_machine, :transitions], transition)
      end)

    {:ok, dsl}
  end

  defp build_transitions(steps) do
    Enum.flat_map(steps, fn step ->
      cond do
        step.terminal ->
          []

        step.manual ->
          manual_transitions(step) ++ timeout_transitions(step)

        true ->
          automatic_transitions(step) ++ timeout_transitions(step)
      end
    end)
  end

  defp automatic_transitions(step) do
    success = build_transition(step.action, [step.name], [step.on_success])

    error =
      if step.on_error do
        [build_transition(step.action, [step.name], [step.on_error])]
      else
        []
      end

    [success | error]
  end

  defp manual_transitions(step) do
    Enum.map(step.transitions, fn transition ->
      targets = Transition.all_targets(transition)
      build_transition(transition.name, [step.name], targets)
    end)
  end

  defp timeout_transitions(step) do
    step.timeouts
    |> Enum.filter(& &1.transition_to)
    |> Enum.map(fn timeout ->
      build_transition(:"__timeout_#{timeout.name}", [step.name], [timeout.transition_to])
    end)
  end

  defp build_transition(action, from, to) do
    Transformer.build_entity!(AshStateMachine, [:state_machine, :transitions], :transition,
      action: action,
      from: from,
      to: to
    )
  end

  def before?(AshStateMachine.Transformers.FillInTransitionDefaults), do: true
  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(AshStateMachine.Transformers.EnsureStateSelected), do: true
  def before?(_), do: false
end
