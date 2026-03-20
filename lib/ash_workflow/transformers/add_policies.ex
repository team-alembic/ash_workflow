defmodule AshWorkflow.Transformers.AddPolicies do
  @moduledoc """
  Generates Ash policies from workflow step declarations.

  Ensures workflow resources work out of the box when `Ash.Policy.Authorizer`
  is present by injecting three layers of policies:

  1. **AshOban bypass** — allows Oban-triggered actions (automatic steps and
     timeouts) to execute without an actor. Uses `AshOban.Checks.AshObanInteraction`
     which only matches when `context.private.ash_oban?` is true.

  2. **Step-level policies** — for each manual step with a `policy` field,
     generates a policy scoped to that step's transition actions. For example:

         step :review do
           manual true
           policy actor_attribute_equals(:role, :reviewer)
           transition :approve, to: :done
           transition :reject, to: :rejected
         end

     Generates:

         policy action([:approve, :reject]) do
           authorize_if {Ash.Policy.Check.ActorAttributeEquals, ...}
         end

  3. **Default allow** — a catch-all `authorize_if always()` scoped to all
     workflow-generated action names, so actions like `:start` and automatic
     steps aren't blocked by other policies on the resource.

  Skips all policy generation if `Ash.Policy.Authorizer` is not configured
  on the resource.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def transform(dsl) do
    authorizers = Transformer.get_persisted(dsl, :authorizers) || []

    unless Ash.Policy.Authorizer in authorizers do
      {:ok, dsl}
    else
      steps = Transformer.get_entities(dsl, [:workflow])
      existing_policies = Transformer.get_entities(dsl, [:policies])

      workflow_action_names = collect_workflow_action_names(steps)
      oban_action_names = collect_oban_action_names(steps)

      dsl =
        if oban_action_names != [] do
          add_oban_bypass(dsl, oban_action_names)
        else
          dsl
        end

      dsl =
        steps
        |> Enum.filter(&(&1.manual && &1.policy))
        |> Enum.reduce(dsl, fn step, dsl ->
          add_step_policy(dsl, step, existing_policies)
        end)

      dsl = add_default_allow_policy(dsl, workflow_action_names)

      {:ok, dsl}
    end
  end

  defp collect_workflow_action_names(steps) do
    start_actions = [:start, :read]

    transition_actions =
      steps
      |> Enum.filter(& &1.manual)
      |> Enum.flat_map(& &1.transitions)
      |> Enum.map(& &1.name)

    automatic_actions =
      steps
      |> Enum.reject(&(&1.manual || &1.terminal))
      |> Enum.map(& &1.action)

    timeout_actions =
      steps
      |> Enum.reject(& &1.terminal)
      |> Enum.flat_map(& &1.timeouts)
      |> Enum.map(fn timeout ->
        if timeout.transition_to do
          :"__timeout_#{timeout.name}"
        else
          timeout.action
        end
      end)

    Enum.uniq(start_actions ++ transition_actions ++ automatic_actions ++ timeout_actions)
  end

  defp collect_oban_action_names(steps) do
    automatic_actions =
      steps
      |> Enum.reject(&(&1.manual || &1.terminal))
      |> Enum.map(& &1.action)

    timeout_actions =
      steps
      |> Enum.reject(& &1.terminal)
      |> Enum.flat_map(& &1.timeouts)
      |> Enum.map(fn timeout ->
        if timeout.transition_to do
          :"__timeout_#{timeout.name}"
        else
          timeout.action
        end
      end)

    Enum.uniq(automatic_actions ++ timeout_actions)
  end

  defp add_oban_bypass(dsl, oban_action_names) do
    authorize_if =
      Transformer.build_entity!(Ash.Policy.Authorizer, [:policies, :policy], :authorize_if,
        check: Ash.Policy.Check.Builtins.always()
      )

    bypass =
      Transformer.build_entity!(Ash.Policy.Authorizer, [:policies], :bypass,
        condition: [
          Ash.Policy.Check.Builtins.action(oban_action_names),
          {AshOban.Checks.AshObanInteraction, []}
        ],
        policies: [authorize_if]
      )

    Transformer.add_entity(dsl, [:policies], bypass)
  end

  defp add_step_policy(dsl, step, existing_policies) do
    transition_names = Enum.map(step.transitions, & &1.name)

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

  defp add_default_allow_policy(dsl, workflow_action_names) do
    authorize_if =
      Transformer.build_entity!(Ash.Policy.Authorizer, [:policies, :policy], :authorize_if,
        check: Ash.Policy.Check.Builtins.always()
      )

    policy =
      Transformer.build_entity!(Ash.Policy.Authorizer, [:policies], :policy,
        condition: Ash.Policy.Check.Builtins.action(workflow_action_names),
        policies: [authorize_if]
      )

    Transformer.add_entity(dsl, [:policies], policy)
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
