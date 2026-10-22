defmodule AshWorkflow.Entities.Every do
  @moduledoc """
  Defines a recurring action entity with its configuration schema.

  `every` is not a timeout: nothing is timing out. It is a recurring action
  that runs on an interval for as long as a record sits in its step. Firing
  never leaves the step — there is no `transition_to` — so `every` always
  requires an `action`.

  ## Storage

  `AshWorkflow.Transformers.AddAttributes` adds one nilable
  `:utc_datetime_usec` attribute per `every`, holding the instant it last
  fired. Its `interval` is measured against that column, not against
  `state_entered_at`, so two `every` entities on the same step — and any
  `timeout` sharing the step — no longer share one anchor that one firing
  resets out from under the others.

  Named `<step>_<every>_last_fired_at` by default, or explicitly with
  `last_fired_field`:

      every :reminder do
        interval {1, :hours}
        action :send_reminder
        last_fired_field :reminder_last_fired_at
      end

  Not `field` — `AshWorkflow.Entities.Timeout`'s `field` names an anchor
  AshWorkflow reads and never writes. `last_fired_field` names a column
  AshWorkflow owns and writes on every fire. Reusing the name would give it
  two opposite meanings.

  A record whose column is still `nil` has never fired this `every`, and the
  interval is then measured from `state_entered_at`, so the first firing lands
  one whole interval after the record entered the step rather than on entry.
  Both the generated Oban trigger and
  `AshWorkflow.Scheduler.Precise.Timeline` apply that fallback.

  ## Bounding an `every` with `until`

  `every` alone fires forever. `until` stops it after a fixed amount of
  wall-clock time since the record entered the step:

      every :reminder do
        interval {2, :days}
        action :send_review_reminder
        until {8, :days}
      end

  `until` is measured against `state_entered_at` directly. An `every`'s own
  firing writes its `last_fired_field`, not `state_entered_at`, so
  `state_entered_at` stays put for as long as the record occupies the step —
  nothing moves the anchor `until` measures against. See
  `AshWorkflow.Verifiers.ValidateEvery` for why `until` must be strictly
  longer than `interval`.

  Reaching the bound only stops the firing. It does not transition state —
  compose a second, ordinary timeout with a `fire_after` equal to the bound
  for "give up and move on".

  ## Bounding an `every` with `max_fires`

  `max_fires` stops it after a number of fires in the current step visit:

      every :reminder do
        interval {2, :days}
        action :send_review_reminder
        max_fires 3
      end

  ## Spacing fires out with `backoff`

  `backoff` grows the gap between fires. The first fire still lands one
  `interval` after entry. After fire `n`, the next lands `interval` plus
  `AshWorkflow.Entities.Retry.delay_ms/2` for attempt `n` later, so a fixed
  duration adds the same delay to every later gap and `:exponential` adds
  Oban's `n^4 + 15` seconds.

  Both options add a `<step>_<every>_fires` integer column holding the fires
  in the current step visit. A fire recorded before `state_entered_at` belongs
  to an earlier visit, so the count restarts on re-entry.
  """

  alias AshWorkflow.Entities.Retry

  defstruct [
    :name,
    :interval,
    :action,
    :until,
    :check_interval,
    :last_fired_field,
    :max_fires,
    :backoff,
    self_scheduled?: false,
    __spark_metadata__: nil,
    retry: nil
  ]

  @type duration_unit :: AshWorkflow.Duration.unit()
  @type t :: %__MODULE__{
          name: atom(),
          interval: {pos_integer(), duration_unit()},
          action: atom(),
          until: AshWorkflow.Duration.t() | nil,
          check_interval: String.t() | nil,
          last_fired_field: atom() | nil,
          max_fires: pos_integer() | nil,
          backoff: AshWorkflow.Entities.Retry.backoff() | nil,
          self_scheduled?: boolean(),
          retry: AshWorkflow.Entities.Retry.t() | nil
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "A unique name for this recurring action."
    ],
    interval: [
      type: {:custom, __MODULE__, :validate_duration, []},
      required: true,
      doc: "Duration tuple, e.g. `{1, :day}` or `{2, :hours}`."
    ],
    action: [
      type: :atom,
      required: true,
      doc: "Action to run each time the interval elapses. Does not change state."
    ],
    until: [
      type: {:custom, AshWorkflow.Duration, :validate, []},
      doc: """
      Stop firing once this much wall-clock time has passed since the record
      entered the step.

      Measured against `state_entered_at` directly, which an `every`'s own
      firing no longer touches. Must be strictly longer than `interval`,
      since equal to it leaves no room to fire even once.
      """
    ],
    self_scheduled?: [
      type: :boolean,
      default: false,
      doc: """
      Declares that you run this action's trigger yourself, more often than a
      cron expression can ask for.

      Cron cannot poll more often than once a minute, so a sub-minute
      `interval` is normally a compile error — the action would fire up to 60
      seconds late. Setting this asserts that something else drives the
      trigger at the resolution the interval needs, and permits the shorter
      duration.

      This changes nothing about what is generated: the scheduler module and
      its cron are still created, so `AshOban.schedule/2` and
      `AshOban.schedule_and_run_triggers/1` keep working. It only records the
      claim, and silences the check that would otherwise reject the duration.
      """
    ],
    check_interval: [
      type: :string,
      doc: """
      Oban cron expression for how often to check this action, overriding the
      workflow-level `check_interval`. Defaults to the workflow's setting,
      which itself defaults to every minute.
      """
    ],
    last_fired_field: [
      type: :atom,
      doc: """
      The datetime attribute this `every` writes its last-fired instant to,
      and measures `interval` against. Defaults to
      `<step>_<every>_last_fired_at`. AshWorkflow adds this attribute and
      owns every write to it — see `AshWorkflow.Transformers.AddAttributes`.
      """
    ],
    max_fires: [
      type: :pos_integer,
      doc: """
      Stop firing after this many fires in the current step visit. Adds a
      `<step>_<every>_fires` integer column. May be combined with `until`, and
      whichever bound is reached first stops the firing.
      """
    ],
    backoff: [
      type: {:or, [{:custom, AshWorkflow.Duration, :validate, []}, {:literal, :exponential}]},
      doc: """
      Grow the gap between fires. After fire `n`, the next fire lands
      `interval` plus `AshWorkflow.Entities.Retry.delay_ms/2` for attempt `n`
      later. A duration tuple adds a fixed delay, and `:exponential` adds
      `n^4 + 15` seconds. Adds a `<step>_<every>_fires` integer column.
      """
    ]
  ]

  def attribute_schema, do: @schema

  def validate_duration(value), do: AshWorkflow.Duration.validate(value)

  @doc """
  The attribute this `every` writes its last-fired instant to, and measures
  `interval` against: `last_fired_field` if given, otherwise
  `<step_name>_<every_name>_last_fired_at`.
  """
  @spec last_fired_field(atom(), t()) :: atom()
  def last_fired_field(_step_name, %__MODULE__{last_fired_field: field}) when not is_nil(field),
    do: field

  def last_fired_field(step_name, %__MODULE__{name: name}),
    do: :"#{step_name}_#{name}_last_fired_at"

  @doc """
  The integer attribute counting this `every`'s fires in the current step
  visit, `<step_name>_<every_name>_fires`, or `nil` when the `every` declares
  neither `max_fires` nor `backoff` and so needs no count.
  """
  @spec fires_field(atom(), t()) :: atom() | nil
  def fires_field(_step_name, %__MODULE__{max_fires: nil, backoff: nil}), do: nil
  def fires_field(step_name, %__MODULE__{name: name}), do: :"#{step_name}_#{name}_fires"

  @doc """
  The gap in milliseconds between fire number `fires` and the next one.

  `fires` of 0 is the gap from step entry to the first fire, which is
  `interval` whatever the `backoff`.
  """
  @spec gap_ms(
          AshWorkflow.Duration.t(),
          Retry.backoff() | nil,
          non_neg_integer()
        ) ::
          non_neg_integer()
  def gap_ms(interval, nil, _fires), do: AshWorkflow.Duration.to_milliseconds(interval)
  def gap_ms(interval, _backoff, 0), do: AshWorkflow.Duration.to_milliseconds(interval)

  def gap_ms(interval, backoff, fires) do
    AshWorkflow.Duration.to_milliseconds(interval) +
      Retry.delay_ms(%Retry{backoff: backoff}, fires)
  end

  @doc """
  The instant this `every` is next due, given the record's last-fired instant,
  its fire count and its `state_entered_at`.

  A `nil` last fire measures `interval` from `state_entered_at`. A last fire
  from an earlier step visit counts as zero fires in this one.
  """
  @spec next_due_at(
          AshWorkflow.Duration.t(),
          Retry.backoff() | nil,
          DateTime.t() | nil,
          non_neg_integer() | nil,
          DateTime.t()
        ) :: DateTime.t()
  def next_due_at(interval, backoff, nil, _fires, state_entered_at),
    do: DateTime.add(state_entered_at, gap_ms(interval, backoff, 0), :millisecond)

  def next_due_at(interval, backoff, last_fired_at, fires, state_entered_at) do
    visit_fires =
      if DateTime.compare(last_fired_at, state_entered_at) == :lt, do: 0, else: fires || 0

    DateTime.add(last_fired_at, gap_ms(interval, backoff, visit_fires), :millisecond)
  end
end
