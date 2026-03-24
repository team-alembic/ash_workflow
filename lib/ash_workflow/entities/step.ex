defmodule AshWorkflow.Entities.Step do
  @moduledoc "Defines a workflow step entity with its configuration schema."

  defstruct [
    :name,
    :action,
    :on_success,
    :on_error,
    :policy,
    manual: false,
    terminal: false,
    transitions: [],
    timeouts: []
  ]

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
    manual: [
      type: :boolean,
      default: false,
      doc: "If true, this step waits for a human to trigger a transition action."
    ],
    terminal: [
      type: :boolean,
      default: false,
      doc: "If true, this is an end state with no outgoing transitions."
    ],
    on_success: [
      type: :atom,
      doc: "The step to transition to on successful completion. Required for automatic steps."
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
end
