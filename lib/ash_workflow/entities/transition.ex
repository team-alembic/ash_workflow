defmodule AshWorkflow.Entities.Transition do
  @moduledoc """
  A named transition from a manual step to another step.

  Simple transitions have a static `to` target:

      transition :approve, to: :done

  Conditional transitions have `routes` instead — multiple targets with `when` conditions:

      transition :complete do
        route :training, when: expr(path_type == :agency)
        route :ready, when: expr(path_type == :family)
      end

  A transition must have either `to` or at least one route, not both.

  Routes are evaluated in declaration order and the first match wins.
  Conditions see the record as it was loaded with the transition's `accept`
  list applied, so a route can branch on an attribute the same call accepted,
  while an attribute written by the action's own changes stays invisible:

      transition :decide do
        accept [:decision]
        route :approved, when: expr(decision == :approve)
        route :rejected, when: expr(decision == :reject)
      end
  """
  defstruct [:name, :to, __spark_metadata__: nil, accept: [], routes: [], undoable?: false]

  @type t :: %__MODULE__{
          name: atom(),
          to: atom() | nil,
          accept: [atom()],
          routes: [AshWorkflow.Entities.Route.t()],
          undoable?: boolean()
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The name of the transition. Becomes an Ash update action."
    ],
    to: [
      type: :atom,
      doc: "The step to transition to. Omit when using conditional routes."
    ],
    accept: [
      type: {:list, :atom},
      default: [],
      doc: "List of resource attributes the generated transition action should accept as input."
    ],
    undoable?: [
      type: :boolean,
      default: false,
      doc: """
      If true, this transition may be rewound by the generated `undo` action.

      Requires an `undo` block on the workflow. Opt-in per transition rather
      than per workflow, because undoing a decision that has already had
      effects outside the workflow — an offer sent, a payment taken — cannot be
      made safe by the extension. The default is that nothing is undoable.

      Note that undo restores *state*, not attributes: a transition with
      `accept` does not have its accepted values rolled back.
      """
    ]
  ]

  def attribute_schema, do: @schema

  def conditional?(%__MODULE__{routes: routes}) when routes != [], do: true
  def conditional?(_), do: false

  def all_targets(%__MODULE__{to: to, routes: []}) when not is_nil(to), do: [to]
  def all_targets(%__MODULE__{routes: routes}), do: Enum.map(routes, & &1.to)
end
