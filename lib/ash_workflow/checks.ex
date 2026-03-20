defmodule AshWorkflow.Checks do
  @moduledoc """
  Re-exports Ash policy check helpers for use inside workflow step blocks.

  Only includes checks that don't conflict with step DSL option names.
  For checks not listed here, pass the tuple directly:

      policy {Ash.Policy.Check.ActorAttributeEquals, attribute: :role, value: :admin}
  """

  defdelegate actor_attribute_equals(attribute, value), to: Ash.Policy.Check.Builtins
  defdelegate relates_to_actor_via(relationship_path, opts \\ []), to: Ash.Policy.Check.Builtins
  defdelegate actor_present(), to: Ash.Policy.Check.Builtins
end
