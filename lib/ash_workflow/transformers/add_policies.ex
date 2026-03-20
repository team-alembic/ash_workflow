defmodule AshWorkflow.Transformers.AddPolicies do
  @moduledoc """
  Generates Ash policies from step-level `policy` declarations.

  For each manual step with a `policy` field, generates a policy that applies
  to all transition actions in that step. The policy uses `authorize_if` with
  the provided check (any `{module, opts}` tuple implementing `Ash.Policy.Check`).

  For example, a step with:

      step :review do
        manual true
        policy actor_attribute_equals(:role, :reviewer)
        transition :approve, to: :done
        transition :reject, to: :rejected
      end

  Generates:

      policies do
        policy action([:approve, :reject]) do
          authorize_if {Ash.Policy.Check.ActorAttributeEquals, [attribute: :role, value: :reviewer]}
        end
      end

  Skips generating policies for actions that already have user-defined policies
  targeting them.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def transform(dsl) do
    steps = Transformer.get_entities(dsl, [:workflow])
    existing_policies = Transformer.get_entities(dsl, [:policies])

    dsl =
      steps
      |> Enum.filter(&(&1.manual && &1.policy))
      |> Enum.reduce(dsl, fn step, dsl ->
        add_step_policy(dsl, step, existing_policies)
      end)

    {:ok, dsl}
  end

  defp add_step_policy(dsl, step, existing_policies) do
    transition_names = Enum.map(step.transitions, & &1.name)

    # Skip actions that already have user-defined policies
    uncovered_actions =
      Enum.reject(transition_names, fn action_name ->
        Enum.any?(existing_policies, fn policy ->
          action_covered?(policy, action_name)
        end)
      end)

    if uncovered_actions == [] do
      dsl
    else
      authorize_if =
        Transformer.build_entity!(Ash.Policy.Authorizer, [:policies, :policy], :authorize_if,
          check: step.policy
        )

      policy =
        Transformer.build_entity!(Ash.Policy.Authorizer, [:policies], :policy,
          condition: Ash.Policy.Check.Builtins.action(uncovered_actions),
          policies: [authorize_if]
        )

      Transformer.add_entity(dsl, [:policies], policy)
    end
  end

  defp action_covered?(policy, action_name) do
    Enum.any?(List.wrap(policy.condition), fn
      {%{check_module: Ash.Policy.Check.Action, check_opts: opts}, _} ->
        action_name in List.wrap(opts[:action])

      _ ->
        false
    end)
  end

  def before?(_), do: false
end
