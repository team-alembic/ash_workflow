defmodule AshWorkflow.Info do
  @moduledoc """
  Introspection helpers for AshWorkflow resources.
  """

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
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
  Returns the `every` entities declared on a given step, or `[]` if the step
  has none or does not exist.
  """
  @spec everys(Ash.Resource.t(), atom()) :: [AshWorkflow.Entities.Every.t()]
  def everys(resource, step_name) do
    case step(resource, step_name) do
      nil -> []
      step -> step.everys
    end
  end

  @typedoc """
  The merged view of a transition name, as returned by `transition/2`.
  """
  @type merged_transition :: %{
          name: atom(),
          from: [atom()],
          routes: [%{from: atom(), to: atom(), when: Ash.Expr.t() | nil}],
          accepted_inputs: [atom()],
          generated_action: atom()
        }

  @doc """
  Returns the merged view of a transition name, or `nil` if no step declares it.

  A transition name declared on more than one step becomes a single generated
  action, and the declarations merge: `from` lists every step the action moves
  out of, `routes` holds one entry per declared target with the `when`
  expression that selects it, and `accepted_inputs` is the union of every
  declaration's `accept`.

  A route from a static transition has a `when` of `nil`. The step it leaves is
  on the route itself, so a caller reading a route never has to pair it back up
  with a step.

  ## Example

      AshWorkflow.Info.transition(MyApp.OnboardingWorkflow, :complete)
      #=> %{
      #=>   name: :complete,
      #=>   from: [:initial_review, :detailed_review],
      #=>   routes: [
      #=>     %{from: :initial_review, to: :detailed_review, when: nil},
      #=>     %{from: :detailed_review, to: :approved, when: nil}
      #=>   ],
      #=>   accepted_inputs: [:notes],
      #=>   generated_action: :complete
      #=> }
  """
  @spec transition(Ash.Resource.t() | map(), atom()) :: merged_transition() | nil
  def transition(resource, name) do
    declarations =
      resource
      |> steps()
      |> Enum.filter(&Step.manual?/1)
      |> Enum.flat_map(fn step -> Enum.map(step.transitions, &{step.name, &1}) end)
      |> Enum.filter(fn {_step, transition} -> transition.name == name end)

    case declarations do
      [] -> nil
      declarations -> merge_declarations(name, declarations)
    end
  end

  defp merge_declarations(name, declarations) do
    %{
      name: name,
      from: declarations |> Enum.map(fn {step, _} -> step end) |> Enum.uniq(),
      routes: Enum.flat_map(declarations, &declared_routes/1),
      accepted_inputs:
        declarations |> Enum.flat_map(fn {_step, t} -> t.accept end) |> Enum.uniq(),
      generated_action: name
    }
  end

  defp declared_routes({step_name, %Transition{routes: []} = transition}) do
    [%{from: step_name, to: transition.to, when: nil}]
  end

  defp declared_routes({step_name, %Transition{routes: routes}}) do
    Enum.map(routes, &%{from: step_name, to: &1.to, when: &1.when})
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
      %Step{} = step -> Step.terminal?(step)
      _ -> false
    end
  end

  @doc """
  Returns `true` if the given record is in a terminal state.

  The record must have its state attribute loaded.
  """
  @spec in_terminal_state?(Ash.Resource.record()) :: boolean()
  def in_terminal_state?(%{__struct__: resource} = record) do
    case Map.get(record, state_attribute(resource)) do
      state when is_atom(state) and not is_nil(state) -> terminal?(resource, state)
      _ -> false
    end
  end

  @doc """
  Returns the attribute the workflow stores its current step in.

  Defaults to `:state`. A workflow overrides it with `state_attribute` on the
  `workflow` section, which is passed down to `ash_state_machine`.
  """
  @spec state_attribute(Ash.Resource.t() | map()) :: atom()
  def state_attribute(resource) do
    Extension.get_opt(resource, [:workflow], :state_attribute, nil) ||
      AshStateMachine.Info.state_machine_state_attribute!(resource)
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
  Returns the workflow's scheduler as `{module, options}`.

  Falls back to the `:scheduler` application environment for `:ash_workflow`,
  and then to `AshWorkflow.Scheduler.Oban`.
  """
  @spec scheduler(Ash.Resource.t() | map()) :: {module(), keyword()}
  def scheduler(resource) do
    case Extension.get_opt(resource, [:workflow], :scheduler, nil) do
      nil -> AshWorkflow.Scheduler.default()
      {module, opts} -> {module, opts}
    end
  end

  @doc """
  Returns every `AshWorkflow.Scheduler.Work` the workflow declares.

  One per automatic step and one per timeout, as
  `AshWorkflow.Transformers.AddScheduler` built them and handed them to the
  selected scheduler. A runtime scheduler reads this rather than re-deriving
  the list from steps and timeouts, so both see exactly the same work.
  """
  @spec scheduled_work(Ash.Resource.t() | map()) :: [AshWorkflow.Scheduler.Work.t()]
  def scheduled_work(resource) do
    Extension.get_persisted(resource, :ash_workflow_scheduled_work, [])
  end

  @doc """
  Returns the composite indexes that make the generated Oban triggers cheap,
  as a list of attribute-name lists, most useful first.

  Every trigger's `where` clause filters on the state attribute, and every
  timeout also filters on the datetime field it reads: its `field`, or its
  `fire_at` when it declares one. Because `ago/2` compiles to a bind
  parameter rather than a per-row function call, a timeout's filter reaches the
  data layer as `state = $1 AND state_entered_at <= $2` — an ordinary composite
  range scan. Without these indexes each poll is a sequential scan.

  A `[state, field]` index also serves the automatic-step triggers, which
  filter on the state attribute alone, since it is the leading column. The
  state attribute is returned on its own when a workflow declares no timeouts
  at all. A workflow that renames the attribute with `state_attribute` gets
  indexes on that name instead.

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
    steps = steps(resource) |> Enum.reject(&Step.terminal?/1)

    every_fields = if Enum.any?(steps, &(&1.everys != [])), do: [:state_entered_at], else: []

    timeout_fields =
      steps
      |> Enum.flat_map(& &1.timeouts)
      |> Enum.map(&Timeout.deadline_field/1)
      |> Enum.concat(every_fields)
      |> Enum.filter(&column?(resource, &1))
      |> Enum.uniq()
      |> Enum.sort_by(&(&1 != :state_entered_at))

    state = state_attribute(resource)

    case timeout_fields do
      [] -> if Enum.any?(steps, &(not Step.manual?(&1))), do: [[state]], else: []
      fields -> Enum.map(fields, &[state, &1])
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

  Each key is a step name, and the value describes that step and every edge
  leaving it, so a caller can draw and label the whole workflow without
  reaching back into the DSL.

  The step itself carries:

  * `:name` — the step name, repeated so an entry stands alone once taken out
    of the map
  * `:action` — the action an automatic step runs, `nil` for every other step
  * `:policy` — the step's `policy` check, or `nil`
  * `:retry` — the step's `AshWorkflow.Entities.Retry`, or `nil`
  * `:initial` — `true` for the step the workflow starts in, as
    `AshWorkflow.Entities.Step.find_initial/1` picks it
  * `:terminal` — `true` for an end state
  * `:manual` — `true` when nothing runs on entry
  * `:wait_state` — `true` when a timeout is the step's only exit

  The edges are five lists:

  * `:transitions` — one entry per reachable target, as `%{name:, to:,
    condition:, undoable?:, accept:}`. A conditional transition contributes one
    entry per route, each carrying that route's `when` expression as
    `:condition`; a simple transition contributes one entry with a `nil`
    condition. `:undoable?` is `true` only when the workflow declares an `undo`
    block and the transition opts in.
  * `:on_success` — one entry per declared `on_success` route, as `%{to:,
    condition:}`.
  * `:on_error` — the step an automatic step falls to on failure, or `nil`.
  * `:timeouts` — one entry per timeout, as `%{name:, to:, fire_after:, fire_at:,
    field:, action:, retry:}`. A timeout that runs an action rather than moving
    the workflow has a `nil` `:to` and a non-`nil` `:action`. A `fire_at`
    timeout names the field holding its deadline, so it has a `nil`
    `:fire_after` and a `nil` `:field`.
  * `:everys` — one entry per `every`, as `%{name:, interval:, action:,
    until:, retry:}`. Always measures against `state_entered_at` and never has
    a target, since firing never leaves the step. `:until` is `nil` unless the
    `every` bounds its firing.

  ## Example

      AshWorkflow.Info.workflow_graph(MyApp.OnboardingWorkflow)
      #=> %{
      #=>   screening: %{
      #=>     name: :screening,
      #=>     action: nil,
      #=>     policy: nil,
      #=>     retry: nil,
      #=>     initial: true,
      #=>     terminal: false,
      #=>     manual: true,
      #=>     wait_state: false,
      #=>     transitions: [
      #=>       %{name: :advance, to: :interviewing, condition: nil, undoable?: true, accept: [:notes]},
      #=>       %{name: :reject, to: :rejected, condition: nil, undoable?: false, accept: []}
      #=>     ],
      #=>     on_success: [],
      #=>     on_error: nil,
      #=>     timeouts: [
      #=>       %{name: :breach, to: :escalated, fire_after: {1, :hours}, fire_at: nil, field: :state_entered_at, action: nil, retry: nil},
      #=>       %{name: :expire, to: :expired, fire_after: nil, fire_at: :offer_expires_at, field: nil, action: nil, retry: nil}
      #=>     ],
      #=>     everys: [
      #=>       %{name: :chase, interval: {3, :days}, action: :send_reminder, until: nil, retry: nil}
      #=>     ]
      #=>   },
      #=>   ...
      #=> }
  """
  @spec workflow_graph(Ash.Resource.t()) :: %{atom() => map()}
  def workflow_graph(resource) do
    steps = steps(resource)
    initial = Step.find_initial(steps)
    undo_enabled? = undo(resource) != nil

    Map.new(steps, &step_to_graph_entry(&1, initial, undo_enabled?))
  end

  defp step_to_graph_entry(step, initial, undo_enabled?) do
    {step.name,
     %{
       name: step.name,
       action: step.action,
       policy: step.policy,
       retry: step.retry,
       initial: step == initial,
       terminal: Step.terminal?(step),
       manual: Step.manual?(step),
       wait_state: Step.wait_state?(step),
       transitions: Enum.flat_map(step.transitions, &transition_edges(&1, undo_enabled?)),
       on_success: Enum.map(step.on_success, &%{to: &1.to, condition: &1.when}),
       on_error: step.on_error,
       timeouts: Enum.map(step.timeouts, &timeout_edge/1),
       everys: Enum.map(step.everys, &every_edge/1)
     }}
  end

  defp transition_edges(%Transition{routes: []} = transition, undo_enabled?) do
    [transition_edge(transition, transition.to, nil, undo_enabled?)]
  end

  defp transition_edges(%Transition{routes: routes} = transition, undo_enabled?) do
    Enum.map(routes, &transition_edge(transition, &1.to, &1.when, undo_enabled?))
  end

  defp transition_edge(transition, to, condition, undo_enabled?) do
    %{
      name: transition.name,
      to: to,
      condition: condition,
      undoable?: undo_enabled? and transition.undoable?,
      accept: transition.accept
    }
  end

  defp timeout_edge(timeout) do
    %{
      name: timeout.name,
      to: timeout.transition_to,
      fire_after: timeout.fire_after,
      fire_at: timeout.fire_at,
      field: if(timeout.fire_at, do: nil, else: Timeout.anchor_field(timeout)),
      action: timeout.action,
      retry: timeout.retry
    }
  end

  defp every_edge(every) do
    %{
      name: every.name,
      interval: every.interval,
      action: every.action,
      until: every.until,
      retry: every.retry
    }
  end
end
