defmodule AshWorkflow.Entities.Transition do
  @moduledoc """
  A named transition from a manual step to another step.

  Simple transitions have a static `to` target:

      transition :approve, to: :done

  Conditional transitions have `routes` instead — multiple targets with `when` conditions:

      transition :complete do
        to :training, when: expr(path_type == :agency)
        to :ready, when: expr(path_type == :family)
      end

  A transition must have either `to` or at least one route, not both.
  """
  defstruct [:name, :to, __spark_metadata__: nil, accept: [], routes: []]

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
    ]
  ]

  def attribute_schema, do: @schema

  def conditional?(%__MODULE__{routes: routes}) when routes != [], do: true
  def conditional?(_), do: false

  def all_targets(%__MODULE__{to: to, routes: []}) when not is_nil(to), do: [to]
  def all_targets(%__MODULE__{routes: routes}), do: Enum.map(routes, & &1.to)
end
