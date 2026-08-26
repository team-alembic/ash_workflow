defmodule AshWorkflow.Entities.Step do
  @moduledoc "Defines a workflow step entity with its configuration schema."

  defstruct [
    :name,
    :action,
    :on_success,
    :on_error,
    :policy,
    __spark_metadata__: nil,
    initial: false,
    terminal: false,
    transitions: [],
    timeouts: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          action: atom() | nil,
          on_success: atom() | nil,
          on_error: atom() | nil,
          policy: term() | nil,
          initial: boolean(),
          terminal: boolean(),
          transitions: [AshWorkflow.Entities.Transition.t()],
          timeouts: [AshWorkflow.Entities.Timeout.t()]
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
      doc: "If true, this is an end state with no outgoing transitions."
    ],
    on_success: [
      type: :atom,
      doc:
        "The step to transition to on successful completion of an automatic step. " <>
          "Required for automatic steps (i.e., steps with an `action` and no `transitions`)."
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
  Returns `true` if the step is a manual step — i.e., it has declared
  transitions and is not a terminal state.

  Manual-ness is derived from the shape of the step: a step with
  `transitions` is manual; a step with an `action` is automatic; a step
  with `terminal: true` is an end state.

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
  Finds the initial step from a list of steps.

  Returns the step with `initial: true`, or falls back to the first
  non-terminal step by declaration order.
  """
  def find_initial(steps) do
    Enum.find(steps, & &1.initial) || steps |> Enum.reject(& &1.terminal) |> List.first()
  end
end
