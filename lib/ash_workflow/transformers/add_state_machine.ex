defmodule AshWorkflow.Transformers.AddStateMachine do
  @moduledoc """
  Generates ash_state_machine configuration from workflow steps.

  Injects the following into the resource's `state_machine` DSL:

  - **`state_attribute`** — the workflow's `state_attribute`, when it declares one.
  - **`initial_states`** — set to the step with `initial: true`, or the first
    non-terminal step by declaration order if none is marked.
  - **`default_initial_state`** — same as above
  - **Transitions** for each step type:
    - *Automatic steps* — `transition :step_action, from: [:step_name], to: [...]`, where
      `to` is every target across the step's `on_success` entries.
      If `on_error` is set, a transition named `__on_error_<step>` to the error
      state is added — declared on the error handler action rather than on the
      step's own action, since that is what AshOban invokes when the step fails.
    - *Manual steps* — one transition per declared `transition` entity,
      e.g. `transition :approve, from: [:review], to: [:approved]`
    - *Undoable transitions* — when the workflow declares an `undo` block, two
      `:undo` transitions per undoable edge, one in each direction, so both a
      rewind and a subsequent redo are permitted.
    - *Timeouts with `transition_to`* — a transition named `__timeout_<step>_<name>`,
      e.g. `transition :__timeout_review_escalation, from: [:review], to: [:escalated]`

  Must run before all `AshStateMachine.Transformers.*` so that the state machine
  extension sees the generated states and transitions.
  """
  use Spark.Dsl.Transformer

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Transition
  alias AshWorkflow.Info
  alias AshWorkflow.Transformers.AddActions
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def transform(dsl) do
    steps =
      dsl
      |> Transformer.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    case Step.find_initial(steps) do
      nil -> raise no_steps_error()
      first_step -> add_state_machine(dsl, steps, first_step)
    end
  end

  # A resource with the extension but no steps yet — where every resource sits
  # between `mix ash.extend` and its first step. `validate_workflow` reports
  # this too, but verifiers run after transformers, and there is no state
  # machine to build without a step to start in. Raising the same error here
  # keeps the message the user sees the useful one rather than an internal
  # `expected a map, got: nil`, or ash_state_machine complaining downstream
  # about the `initial_states` this transformer never set.
  defp no_steps_error do
    DslError.exception(
      path: [:workflow],
      message: "Workflow must have at least one non-terminal step."
    )
  end

  defp add_state_machine(dsl, steps, first_step) do
    dsl =
      dsl
      |> put_state_attribute()
      |> Transformer.set_option([:state_machine], :initial_states, [first_step.name])
      |> Transformer.set_option([:state_machine], :default_initial_state, first_step.name)

    transitions = build_transitions(steps) ++ undo_transitions(dsl)

    dsl =
      Enum.reduce(transitions, dsl, fn transition, dsl ->
        Transformer.add_entity(dsl, [:state_machine, :transitions], transition)
      end)

    {:ok, dsl}
  end

  # Only set when the workflow declared one, so a resource configuring
  # ash_state_machine directly keeps whatever it set there.
  defp put_state_attribute(dsl) do
    case Transformer.get_option(dsl, [:workflow], :state_attribute) do
      nil -> dsl
      attribute -> Transformer.set_option(dsl, [:state_machine], :state_attribute, attribute)
    end
  end

  defp build_transitions(steps) do
    Enum.flat_map(steps, fn step ->
      cond do
        Step.terminal?(step) ->
          []

        Step.manual?(step) ->
          manual_transitions(step) ++ timeout_transitions(step)

        true ->
          automatic_transitions(step) ++ timeout_transitions(step)
      end
    end)
  end

  # Two entries per undoable edge, both on the `:undo` action: one to rewind
  # the move, one to re-apply it. The second is what makes undoing an undo
  # legal — the state machine has to permit the redo direction even though the
  # forward transition that normally travels it is a different action.
  defp undo_transitions(dsl) do
    dsl
    |> Info.undoable_edges()
    |> Enum.flat_map(fn {from_state, to_state} ->
      [
        build_transition(AddActions.undo_action_name(), [to_state], [from_state]),
        build_transition(AddActions.undo_action_name(), [from_state], [to_state])
      ]
    end)
  end

  defp automatic_transitions(step) do
    success = build_transition(step.action, [step.name], Step.on_success_targets(step))

    error =
      if step.on_error do
        [
          build_transition(
            AddActions.on_error_action_name(step),
            [step.name],
            [step.on_error]
          )
        ]
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
      build_transition(
        AddActions.timeout_action_name(step, timeout),
        [step.name],
        [timeout.transition_to]
      )
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
