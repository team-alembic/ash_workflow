defmodule AshWorkflow.Info do
  @moduledoc """
  Introspection helpers for AshWorkflow resources.
  """

  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Extension

  @doc """
  Returns all workflow step entities for a resource.
  """
  @spec steps(Ash.Resource.t()) :: [Step.t()]
  def steps(resource) do
    Extension.get_entities(resource, [:workflow])
  end

  @doc """
  Returns a single workflow step by name, or `nil` if not found.
  """
  @spec step(Ash.Resource.t(), atom()) :: Step.t() | nil
  def step(resource, step_name) do
    Enum.find(steps(resource), &(&1.name == step_name))
  end

  @doc """
  Returns the list of user-facing action names available at a given step.

  For manual steps, returns the transition names. For automatic and terminal
  steps, returns an empty list.
  """
  @spec available_actions(Ash.Resource.t(), atom()) :: [atom()]
  def available_actions(resource, step_name) do
    case step(resource, step_name) do
      %{manual: true, transitions: transitions} ->
        Enum.map(transitions, & &1.name)

      _ ->
        []
    end
  end

  @doc """
  Returns `true` if the given step is terminal (an end state with no outgoing transitions).
  """
  @spec terminal?(Ash.Resource.t(), atom()) :: boolean()
  def terminal?(resource, step_name) do
    case step(resource, step_name) do
      %{terminal: true} -> true
      _ -> false
    end
  end

  @doc """
  Returns `true` if the given record is in a terminal state.

  The record must have its `:state` attribute loaded.
  """
  @spec in_terminal_state?(Ash.Resource.record()) :: boolean()
  def in_terminal_state?(%{__struct__: resource, state: state}) when is_atom(state) do
    terminal?(resource, state)
  end

  @doc """
  Returns the initial step for the workflow.
  """
  @spec initial_step(Ash.Resource.t()) :: Step.t() | nil
  def initial_step(resource) do
    Step.find_initial(steps(resource))
  end

  @doc """
  Returns a graph representation of the workflow as a map.

  Each key is a step name, and the value is a map with `:transitions` (list of
  target step names from manual transitions), `:on_success`/`:on_error` (for
  automatic steps), and `:timeouts` (list of `{timeout_name, target}` tuples).

  ## Example

      AshWorkflow.Info.workflow_graph(MyApp.OnboardingWorkflow)
      #=> %{
      #=>   screening: %{transitions: [:interviewing, :rejected], on_success: nil, on_error: nil, timeouts: []},
      #=>   interviewing: %{transitions: [:offer, :rejected], on_success: nil, on_error: nil, timeouts: []},
      #=>   ...
      #=> }
  """
  @spec workflow_graph(Ash.Resource.t()) :: %{atom() => map()}
  def workflow_graph(resource) do
    resource
    |> steps()
    |> Map.new(&step_to_graph_entry/1)
  end

  defp step_to_graph_entry(step) do
    transition_targets = Enum.flat_map(step.transitions, &transition_targets/1)

    timeout_targets =
      step.timeouts
      |> Enum.filter(& &1.transition_to)
      |> Enum.map(&{&1.name, &1.transition_to})

    {step.name,
     %{
       transitions: transition_targets,
       on_success: step.on_success,
       on_error: step.on_error,
       timeouts: timeout_targets,
       terminal: step.terminal,
       manual: step.manual
     }}
  end

  defp transition_targets(%{routes: []} = t), do: [t.to]
  defp transition_targets(%{routes: routes}), do: Enum.map(routes, & &1.to)
end
