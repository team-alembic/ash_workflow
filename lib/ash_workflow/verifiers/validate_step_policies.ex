defmodule AshWorkflow.Verifiers.ValidateStepPolicies do
  @moduledoc """
  Verifies that a workflow declaring a policy has an authorizer to enforce it.

  `AshWorkflow.Transformers.AddPolicies` generates nothing when
  `Ash.Policy.Authorizer` is absent, so a `policy` on a step or on the `undo`
  block was accepted and then never enforced. Every caller was authorized,
  including the ones the policy named. Declaring an authorization rule and
  getting none is the one failure that should never be silent, so it is a
  compile error.
  """
  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Undo
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    if Ash.Policy.Authorizer in (Verifier.get_persisted(dsl, :authorizers) || []) do
      :ok
    else
      dsl
      |> declared_policies()
      |> case do
        [] -> :ok
        declarations -> {:error, error(dsl, declarations)}
      end
    end
  end

  defp declared_policies(dsl) do
    entities = Verifier.get_entities(dsl, [:workflow])

    step_policies =
      entities
      |> Enum.filter(&match?(%Step{policy: policy} when not is_nil(policy), &1))
      |> Enum.map(&"step :#{&1.name}")

    undo_policies =
      entities
      |> Enum.filter(&match?(%Undo{policy: policy} when not is_nil(policy), &1))
      |> Enum.map(fn _undo -> "the undo block" end)

    step_policies ++ undo_policies
  end

  defp error(dsl, declarations) do
    DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:workflow],
      message: """
      #{Enum.join(declarations, ", ")} declares a policy, but this resource has no authorizer, \
      so nothing enforces it.

      Add Ash.Policy.Authorizer to the resource:

          use Ash.Resource,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshWorkflow, AshOban]

      Or remove the policy.
      """
    )
  end
end
