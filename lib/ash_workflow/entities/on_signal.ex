defmodule AshWorkflow.Entities.OnSignal do
  @moduledoc """
  Defines a step's handler for a signal from an `Ash.Signals` module.

  When the signal is emitted, the records in the step that `filter` or
  `read_action` selects either move to `transition_to` or run `action`.
  AshWorkflow generates the read action, the transition action, the
  `signals_in` listener and its policy.
  """

  alias Ash.Resource.SignalListener

  defstruct [
    :name,
    :from,
    :filter,
    :read_action,
    :transition_to,
    :action,
    :inputs,
    :delivery,
    __spark_metadata__: nil,
    emits: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          from: module() | nil,
          filter: term() | nil,
          read_action: atom() | nil,
          transition_to: atom() | nil,
          action: atom() | nil,
          inputs: [{atom(), atom()}] | nil,
          delivery: {module(), Keyword.t()} | nil,
          emits: [AshWorkflow.Entities.Emit.t()]
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The name of the signal."
    ],
    from: [
      type: :atom,
      doc:
        "The `Ash.Signals` module that declares the signal. Defaults to the workflow's `signals` module."
    ],
    filter: [
      type: :any,
      doc:
        "An expression that selects the records to act on, with `^signal(:field)` for fields of the signal, e.g. `expr(id == ^signal(:order_id))`. Exactly one of `filter` or `read_action` is required."
    ],
    read_action: [
      type: :atom,
      doc:
        "A read action of the resource that selects the records to act on. Its arguments are set from the signal fields of the same name. Only records in the step are acted on."
    ],
    transition_to: [
      type: :atom,
      doc: "The step to move to. Exactly one of `transition_to` or `action` is required."
    ],
    action: [
      type: :atom,
      doc: "An update action to run without leaving the step."
    ],
    inputs: [
      type: {:list, {:or, [:atom, {:tuple, [:atom, :atom]}]}},
      doc:
        "Inputs of the action to set from the signal, as `input: :signal_field`. A bare name takes the field with the same name. Passed to the listener unchanged."
    ],
    delivery: [
      type: {:spark_behaviour, Ash.Signals.Delivery},
      doc: "How the signal reaches the handler. Passed to the listener unchanged."
    ]
  ]

  def attribute_schema, do: @schema

  @doc false
  def transform(on_signal) do
    {:ok, %{on_signal | inputs: SignalListener.normalize_mapping(on_signal.inputs)}}
  end

  @doc """
  Whether the handler moves the record to another of `step_names`, and so
  gets a generated transition action.
  """
  @spec transitions?(t(), [atom()]) :: boolean()
  def transitions?(%__MODULE__{action: nil, transition_to: target}, step_names),
    do: target in step_names

  def transitions?(%__MODULE__{}, _step_names), do: false

  @doc "Name of the `signals_in` listener, as `react_to_signal(..., only: ...)` takes it."
  @spec listener_name(atom(), t()) :: atom()
  def listener_name(step_name, %__MODULE__{name: name}), do: :"#{step_name}_#{name}"

  @doc """
  Name of the hidden transition action, scoped by step like
  `AshWorkflow.Transformers.AddActions.timeout_action_name/2`.
  """
  @spec action_name(atom(), t()) :: atom()
  def action_name(step_name, %__MODULE__{name: name}), do: :"__signal_#{step_name}_#{name}"

  @doc "Name of the hidden read action that selects the records in the step."
  @spec read_action_name(atom(), t()) :: atom()
  def read_action_name(step_name, %__MODULE__{} = on_signal),
    do: :"#{action_name(step_name, on_signal)}_read"

  @doc "The action the listener runs: the generated transition, or the handler's `action`."
  @spec listener_action(atom(), t()) :: atom()
  def listener_action(step_name, %__MODULE__{action: nil} = on_signal),
    do: action_name(step_name, on_signal)

  def listener_action(_step_name, %__MODULE__{action: action}), do: action
end
