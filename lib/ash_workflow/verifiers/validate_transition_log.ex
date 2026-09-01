defmodule AshWorkflow.Verifiers.ValidateTransitionLog do
  @moduledoc """
  Verifies that a configured `transition_log` resource has the schema
  `AshWorkflow.Changes.RecordEvent` and the `state_at/2`/`history/1` code
  interface depend on.

  Required attributes: `from_state`, `to_state`, `transition_name`,
  `occurred_at`, `triggered_by`, plus a `belongs_to` relationship back to the
  workflow resource. If `belongs_to_actor` is configured, the log resource
  must also have a matching relationship to the configured actor resource.

  A no-op when no `transition_log` is configured.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @atom_attributes [:from_state, :to_state, :transition_name, :triggered_by]
  @datetime_storage_types [
    :utc_datetime,
    :utc_datetime_usec,
    :naive_datetime,
    :naive_datetime_usec
  ]

  @impl true
  def verify(dsl) do
    case AshWorkflow.Info.transition_log(dsl) do
      nil -> :ok
      log -> validate_log(dsl, log)
    end
  end

  defp validate_log(dsl, log) do
    workflow_module = Verifier.get_persisted(dsl, :module)

    with {:ok, log_resource} <- ensure_resource(log.resource),
         :ok <- validate_atom_attributes(log_resource),
         :ok <- validate_occurred_at(log_resource),
         :ok <- validate_belongs_to_workflow(log_resource, workflow_module) do
      validate_belongs_to_actor(log_resource, log)
    end
  end

  defp ensure_resource(log_resource) do
    case Code.ensure_compiled(log_resource) do
      {:module, module} ->
        if Ash.Resource.Info.resource?(module) do
          {:ok, module}
        else
          {:error,
           transition_log_error(
             "transition_log #{inspect(module)} exists but is not an Ash.Resource."
           )}
        end

      {:error, reason} ->
        {:error,
         transition_log_error(
           "transition_log #{inspect(log_resource)} could not be compiled (#{inspect(reason)}). " <>
             "Scaffold it first with `mix ash_workflow.gen.transition_log`, or check for typos."
         )}
    end
  end

  defp validate_atom_attributes(log_resource) do
    @atom_attributes
    |> Enum.reject(&attribute_type_ok?(log_resource, &1, Ash.Type.Atom))
    |> case do
      [] ->
        :ok

      missing_or_wrong_type ->
        {:error,
         transition_log_error("""
         transition_log #{inspect(log_resource)} is missing required :atom attributes, or \
         has them with the wrong type: #{inspect(missing_or_wrong_type)}.

         A transition log resource must define all of: #{inspect(@atom_attributes)} as :atom \
         attributes.
         """)}
    end
  end

  defp validate_occurred_at(log_resource) do
    if attribute_datetime?(log_resource, :occurred_at) do
      :ok
    else
      {:error,
       transition_log_error("""
       transition_log #{inspect(log_resource)} must define an `occurred_at` attribute with a \
       datetime type (one of #{inspect(@datetime_storage_types)}).
       """)}
    end
  end

  defp attribute_type_ok?(log_resource, name, expected_type) do
    case Ash.Resource.Info.attribute(log_resource, name) do
      nil -> false
      attribute -> attribute.type == expected_type
    end
  end

  defp attribute_datetime?(log_resource, name) do
    case Ash.Resource.Info.attribute(log_resource, name) do
      nil ->
        false

      attribute ->
        Ash.Type.storage_type(attribute.type, attribute.constraints) in @datetime_storage_types
    end
  rescue
    _ -> false
  end

  defp validate_belongs_to_workflow(log_resource, workflow_module) do
    log_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.any?(&(&1.type == :belongs_to and &1.destination == workflow_module))
    |> if do
      :ok
    else
      {:error,
       transition_log_error("""
       transition_log #{inspect(log_resource)} has no `belongs_to` relationship back to \
       #{inspect(workflow_module)}.

       Add one, e.g.:

           belongs_to :workflow, #{inspect(workflow_module)}, allow_nil?: false
       """)}
    end
  end

  defp validate_belongs_to_actor(_log_resource, %{belongs_to_actor: []}), do: :ok

  defp validate_belongs_to_actor(log_resource, %{belongs_to_actor: [actor | _]}) do
    log_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.any?(fn relationship ->
      relationship.type == :belongs_to and relationship.name == actor.name and
        relationship.destination == actor.destination
    end)
    |> if do
      :ok
    else
      {:error,
       transition_log_error("""
       transition_log #{inspect(log_resource)} declares `belongs_to_actor :#{actor.name}, \
       #{inspect(actor.destination)}`, but has no matching `belongs_to :#{actor.name}, \
       #{inspect(actor.destination)}` relationship.

       Add one, e.g.:

           belongs_to :#{actor.name}, #{inspect(actor.destination)}
       """)}
    end
  end

  defp transition_log_error(message) do
    DslError.exception(path: [:workflow, :transition_log], message: message)
  end
end
