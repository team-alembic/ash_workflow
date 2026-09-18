defmodule AshWorkflow.Entities.Step do
  @moduledoc "Defines a workflow step entity with its configuration schema."

  defstruct [
    :name,
    :action,
    :on_error,
    :policy,
    __spark_metadata__: nil,
    initial: false,
    terminal: false,
    transitions: [],
    timeouts: [],
    on_success: [],
    retry: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          action: atom() | nil,
          on_success: [AshWorkflow.Entities.Route.t()],
          on_error: atom() | nil,
          policy: term() | nil,
          initial: boolean(),
          terminal: boolean(),
          transitions: [AshWorkflow.Entities.Transition.t()],
          timeouts: [AshWorkflow.Entities.Timeout.t()],
          retry: AshWorkflow.Entities.Retry.t() | nil
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The name of the step. Becomes a state in the generated state machine."
    ],
    action: [
      type: :atom,
      doc:
        "The action to run for automatic steps. Must reference a user-defined update action on the resource."
    ],
    initial: [
      type: :boolean,
      default: false,
      doc:
        "If true, this step is the initial state. At most one step can be marked initial. If none are, the first non-terminal step by declaration order is used."
    ],
    terminal: [
      type: :boolean,
      default: false,
      doc:
        "Asserts that this is an end state. A step that declares no action, no transitions, no timeouts, no on_success and no on_error is terminal whether or not this is set, so it is only needed to state the intent — the verifier then rejects the step if it grows an outgoing declaration."
    ],
    on_error: [
      type: :atom,
      doc: "The step to transition to on failure. Optional, for automatic steps."
    ],
    policy: [
      type: :any,
      doc:
        "An Ash policy check to apply to all transitions in this step. Accepts any {module, opts} tuple implementing Ash.Policy.Check."
    ]
  ]

  def attribute_schema, do: @schema

  @doc """
  Returns `true` if the step is an end state: nothing runs on entry and nothing
  leaves it.

  Derived from the fields of the step. A step with no action, no transitions, no
  timeouts, no `on_success` and no `on_error` has no way out, so it is terminal
  whether or not it says so. `terminal: true` is an assertion on top of that:
  `AshWorkflow.Verifiers.ValidateWorkflow` rejects a step that declares it and
  then declares something outgoing.

  A step that is terminal by mistake — a name typo'd in one place and not the
  other — is caught by the reachability check rather than here, since an end
  state nothing transitions to is unreachable.
  """
  def terminal?(%__MODULE__{terminal: true}), do: true

  def terminal?(%__MODULE__{
        action: nil,
        transitions: [],
        timeouts: [],
        on_success: [],
        on_error: nil
      }),
      do: true

  def terminal?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the step is a manual step — i.e., it has declared
  transitions and is not a terminal state.

  Manual-ness is derived from the step's fields: a step with
  `transitions` is manual; a step with an `action` is automatic; a step
  with nothing at all is an end state.

  A step with neither transitions nor an action, whose only exit is a
  timeout, is a *wait state* — it is manual in the sense that nothing runs
  on entry, even though no caller can move it along either.
  """
  def manual?(%__MODULE__{terminal: true}), do: false
  def manual?(%__MODULE__{transitions: [_ | _]}), do: true
  def manual?(%__MODULE__{action: nil, timeouts: [_ | _]}), do: true
  def manual?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the step is a wait state — no action runs on entry and no
  caller-facing transition leaves it, so a timeout is its only exit.
  """
  def wait_state?(%__MODULE__{terminal: true}), do: false
  def wait_state?(%__MODULE__{action: nil, transitions: [], timeouts: [_ | _]}), do: true
  def wait_state?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the step's `on_success` needs runtime evaluation to pick
  its target — i.e. it is more than a single unconditional route.

  A single `on_success` entry with no `when` is unconditional and resolves to
  a plain `transition_state`. Anything else (any `when` present, or more than
  one entry) requires evaluating conditions against the record after the
  step's action runs.
  """
  def on_success_conditional?(%__MODULE__{on_success: [%{when: nil}]}), do: false
  def on_success_conditional?(%__MODULE__{on_success: [_ | _]}), do: true
  def on_success_conditional?(%__MODULE__{}), do: false

  @doc """
  Returns every step this step's `on_success` could reach, in declaration
  order. Returns `[]` if no `on_success` is declared.
  """
  def on_success_targets(%__MODULE__{on_success: routes}), do: Enum.map(routes, & &1.to)

  @doc """
  Returns `true` if `on_success` is statically guaranteed to match: it ends
  with an unconditional entry (no `when`), which `validate_on_success_ordering`
  already requires to be both trailing and unique.

  A step whose `on_success` is not exhaustive can, at runtime, run its action
  and have every route's `when` fail to match. `AshWorkflow.Verifiers.ValidateWorkflow`
  uses this to require `on_error` on such a step, since that is otherwise a
  failure the step has no declared way to handle.
  """
  def on_success_exhaustive?(%__MODULE__{on_success: []}), do: false

  def on_success_exhaustive?(%__MODULE__{on_success: routes}),
    do: is_nil(List.last(routes).when)

  @doc """
  Finds the initial step from a list of steps.

  Returns the step with `initial: true`, or falls back to the first
  non-terminal step by declaration order.
  """
  def find_initial(steps) do
    Enum.find(steps, & &1.initial) || steps |> Enum.reject(&terminal?/1) |> List.first()
  end
end
