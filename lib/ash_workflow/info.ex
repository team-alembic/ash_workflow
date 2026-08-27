defmodule AshWorkflow.Info do
  @moduledoc """
  Introspection helpers for AshWorkflow resources.
  """

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Transition
  alias AshWorkflow.Entities.TransitionLog
  alias AshWorkflow.Entities.Undo
  alias Spark.Dsl.Extension

  @doc """
  Returns all workflow step entities for a resource.

  Accepts either a compiled resource module or an in-progress DSL state, so
  transformers can share the same introspection.
  """
  @spec steps(Ash.Resource.t() | map()) :: [Step.t()]
  def steps(resource) do
    resource
    |> Extension.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
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
      nil ->
        []

      step ->
        if Step.manual?(step) do
          Enum.map(step.transitions, & &1.name)
        else
          []
        end
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
  Returns the workflow's `transition_log` configuration, or `nil` if no
  transition log is configured.
  """
  @spec transition_log(Ash.Resource.t() | map()) :: TransitionLog.t() | nil
  def transition_log(resource) do
    resource
    |> Extension.get_entities([:workflow])
    |> Enum.find(&match?(%TransitionLog{}, &1))
  end

  @doc """
  Returns the composite indexes that make the generated Oban triggers cheap,
  as a list of attribute-name lists, most useful first.

  Every trigger's `where` clause filters on `state`, and every timeout also
  filters on its `field`. Because `ago/2` compiles to a bind parameter rather
  than a per-row function call, a timeout's filter reaches the data layer as
  `state = $1 AND state_entered_at <= $2` — an ordinary composite range scan.
  Without these indexes each poll is a sequential scan.

  A `[:state, field]` index also serves the automatic-step triggers, which
  filter on `state` alone, since `state` is the leading column. `[:state]` is
  only returned on its own when a workflow declares no timeouts at all.

  Calculation-backed timeout fields are omitted: they are not columns, so they
  cannot be indexed directly.

  For resources using `AshPostgres.DataLayer` these are added automatically as
  `custom_indexes` — see `AshWorkflow.Transformers.AddIndexes`. This function is
  for everyone else, and for tooling.

  ## Example

      AshWorkflow.Info.recommended_indexes(MyApp.CandidatePipeline)
      #=> [[:state, :state_entered_at], [:state, :last_session_date]]
  """
  @spec recommended_indexes(Ash.Resource.t() | map()) :: [[atom()]]
  def recommended_indexes(resource) do
    steps = steps(resource) |> Enum.reject(& &1.terminal)

    timeout_fields =
      steps
      |> Enum.flat_map(& &1.timeouts)
      |> Enum.map(& &1.field)
      |> Enum.filter(&column?(resource, &1))
      |> Enum.uniq()
      |> Enum.sort_by(&(&1 != :state_entered_at))

    case timeout_fields do
      [] -> if Enum.any?(steps, &(not Step.manual?(&1))), do: [[:state]], else: []
      fields -> Enum.map(fields, &[:state, &1])
    end
  end

  defp column?(resource, field) do
    ResourceInfo.attribute(resource, field) != nil
  end

  @doc """
  Returns the workflow's `undo` configuration, or `nil` if undo is not enabled.
  """
  @spec undo(Ash.Resource.t() | map()) :: Undo.t() | nil
  def undo(resource) do
    resource
    |> Extension.get_entities([:workflow])
    |> Enum.find(&match?(%Undo{}, &1))
  end

  @doc """
  Returns the set of state changes that may be rewound, as `{from_state,
  to_state}` tuples describing the *forward* move.

  A conditional transition contributes one edge per route, so undo permits
  exactly the moves the transition could actually have made. Returns an empty
  list when undo is not enabled.

  ## Example

      AshWorkflow.Info.undoable_edges(MyApp.OnboardingWorkflow)
      #=> [{:review, :approved}, {:review, :rejected}]
  """
  @spec undoable_edges(Ash.Resource.t() | map()) :: [{atom(), atom()}]
  def undoable_edges(resource) do
    if undo(resource) do
      resource
      |> steps()
      |> Enum.filter(&Step.manual?/1)
      |> Enum.flat_map(&step_undoable_edges/1)
      |> Enum.uniq()
    else
      []
    end
  end

  defp step_undoable_edges(step) do
    step.transitions
    |> Enum.filter(& &1.undoable?)
    |> Enum.flat_map(fn transition ->
      Enum.map(Transition.all_targets(transition), &{step.name, &1})
    end)
  end

  @doc """
  Returns `true` if the forward move `from_state -> to_state` may be rewound.
  """
  @spec undoable_edge?(Ash.Resource.t() | map(), atom(), atom()) :: boolean()
  def undoable_edge?(resource, from_state, to_state) do
    {from_state, to_state} in undoable_edges(resource)
  end

  @doc """
  Returns a graph representation of the workflow as a map.

  Each key is a step name, and the value is a map with `:transitions` (list of
  target step names from manual transitions), `:on_success` (the step's
  single unconditional `on_success` target, or `nil` if it has none or is
  conditional), `:on_success_targets` (every step `on_success` could reach —
  one entry per declared `on_success`), `:on_error` (for automatic steps),
  and `:timeouts` (list of `{timeout_name, target}` tuples).

  ## Example

      AshWorkflow.Info.workflow_graph(MyApp.OnboardingWorkflow)
      #=> %{
      #=>   screening: %{transitions: [:interviewing, :rejected], on_success: nil, on_success_targets: [], on_error: nil, timeouts: []},
      #=>   interviewing: %{transitions: [:offer, :rejected], on_success: nil, on_success_targets: [], on_error: nil, timeouts: []},
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
       on_success: bare_on_success(step),
       on_success_targets: Step.on_success_targets(step),
       on_error: step.on_error,
       timeouts: timeout_targets,
       terminal: step.terminal,
       manual: Step.manual?(step)
     }}
  end

  defp bare_on_success(%{on_success: [%{to: to, when: nil}]}), do: to
  defp bare_on_success(%{}), do: nil

  defp transition_targets(%{routes: []} = t), do: [t.to]
  defp transition_targets(%{routes: routes}), do: Enum.map(routes, & &1.to)
end
