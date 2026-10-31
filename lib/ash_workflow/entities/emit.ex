defmodule AshWorkflow.Entities.Emit do
  @moduledoc """
  A signal the workflow fires when a workflow event happens, from the module
  named by the workflow's `signals` option.

  Declared at workflow level it fires on every state change. On a step it
  fires when the record enters or leaves that step, and on a transition,
  timeout or `every` it fires when that runs.
  """

  alias Ash.Resource.SignalListener

  defstruct [:name, on: nil, fields: [], values: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          on: :enter | :exit | nil,
          fields: [{atom(), atom()}],
          values: Keyword.t()
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The name of the signal, declared in the workflow's `signals` module."
    ],
    fields: [
      type: {:list, {:or, [:atom, {:tuple, [:atom, :atom]}]}},
      default: [],
      doc: """
      Signal fields to take from attributes of the record, as a keyword list of
      `signal_field: attribute`. A bare name takes the attribute with the same
      name.
      """
    ],
    values: [
      type: :keyword_list,
      default: [],
      doc: "Signal fields to set to the given literal values."
    ]
  ]

  @step_schema @schema ++
                 [
                   on: [
                     type: {:one_of, [:enter, :exit]},
                     default: :enter,
                     doc: "Whether the signal fires when the record enters or leaves the step."
                   ]
                 ]

  def attribute_schema, do: @schema

  def step_attribute_schema, do: @step_schema

  @doc false
  def transform(emit) do
    {:ok, %{emit | fields: SignalListener.normalize_mapping(emit.fields)}}
  end
end
