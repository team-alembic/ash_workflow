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

  ## Firing at a wall-clock time

  `interval` measures from the last fire, so a daily one drifts to whatever
  time the record entered the step. `at` names a local time instead, and
  `time_zone` places it:

      every :daily_digest do
        at ~T[09:00:00]
        on [:mon, :tue, :wed, :thu, :fri]
        time_zone :candidate_time_zone
        action :send_digest
      end

  One of `at` and `interval` is required. `time_zone` takes an attribute on the
  record, as above, or a literal such as `"Australia/Sydney"`. The attribute
  form is the case a global cron cannot express: two records in the same step
  fire at 09:00 in their own zones, which are two different instants.

  An `interval` declared alongside `at` is a stride rather than a duration:
  how many local days must separate two fires. `on` says which days carry an
  occurrence and the stride says how many of them to skip, so a fortnightly
  digest needs both:

      every :fortnightly_digest do
        interval {14, :days}
        at ~T[09:00:00]
        on [:mon]
        time_zone :candidate_time_zone
        action :send_digest
      end

  A stride must be given in `:days` — see
  `AshWorkflow.Verifiers.ValidateEvery` — and counts local dates rather than
  elapsed time, which is what stops a fire a moment after 09:00 slipping the
  next one by a week. `AshWorkflow.WallClock` has the arithmetic.

  Everything else is unchanged. Firing writes the same `last_fired_field`
  column, `until` still bounds it against `state_entered_at`, and the first
  fire is still the first occurrence after the record entered the step. See
  `AshWorkflow.WallClock` for the occurrence arithmetic, including daylight
  saving, and `documentation/topics/timeouts-and-deadlines.md` for the SQL the
  Oban trigger runs.

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
    :at,
    :on,
    :time_zone,
    :action,
    :until,
    :check_interval,
    :last_fired_field,
    :max_fires,
    :backoff,
    self_scheduled?: false,
    __spark_metadata__: nil,
    retry: nil,
    emits: []
  ]

  @type duration_unit :: AshWorkflow.Duration.unit()
  @type t :: %__MODULE__{
          name: atom(),
          interval: {pos_integer(), duration_unit()} | nil,
          at: Time.t() | nil,
          on: [atom()] | nil,
          time_zone: atom() | String.t() | nil,
          action: atom(),
          until: AshWorkflow.Duration.t() | nil,
          check_interval: String.t() | nil,
          last_fired_field: atom() | nil,
          max_fires: pos_integer() | nil,
          backoff: AshWorkflow.Entities.Retry.backoff() | nil,
          self_scheduled?: boolean(),
          retry: AshWorkflow.Entities.Retry.t() | nil,
          emits: [AshWorkflow.Entities.Emit.t()]
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "A unique name for this recurring action."
    ],
    interval: [
      type: {:custom, __MODULE__, :validate_duration, []},
      doc: """
      Duration tuple, e.g. `{1, :day}` or `{2, :hours}`, measured from this
      `every`'s own last fire.

      Alongside `at` this is a stride instead: how many local days must
      separate two fires. It must then be given in `:days`.

      One of `interval` and `at` is required.
      """
    ],
    at: [
      type: {:custom, __MODULE__, :validate_time, []},
      doc: """
      The wall-clock time this `every` fires at, in the zone `time_zone`
      names, for example `~T[09:00:00]`.

      An `interval` declared beside this becomes a stride in local days
      rather than a duration. See `AshWorkflow.WallClock` for how
      an occurrence is computed, including what happens across a daylight
      saving change.
      """
    ],
    on: [
      type: {:custom, __MODULE__, :validate_days, []},
      doc: """
      The days `at` fires on, as `[:mon, :tue, :wed, :thu, :fri]`. Defaults to
      every day. Only meaningful alongside `at`.
      """
    ],
    time_zone: [
      type: {:custom, __MODULE__, :validate_time_zone, []},
      doc: """
      The zone `at` names a wall-clock time in. One of a literal such as
      `"Australia/Sydney"`, an attribute on the record such as
      `:candidate_time_zone`, or an expression calculation — which is how a
      record reads its zone off a related one:

          calculate :candidate_time_zone, :string, expr(candidate.time_zone)

      A per-record zone is the case a global cron cannot express: two records
      in the same step fire at 09:00 in their own zones, at different
      instants.

      A calculation must be expression-based, since the zone is read from the
      trigger's filter. Required alongside `at`.
      """
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

  def validate_time(%Time{} = value), do: {:ok, value}

  def validate_time(other),
    do: {:error, "Expected a time like ~T[09:00:00], got: #{inspect(other)}"}

  def validate_days(days) when is_list(days) and days != [] do
    case AshWorkflow.WallClock.to_day_numbers(days) do
      {:ok, _numbers} ->
        {:ok, days}

      {:error, day} ->
        {:error,
         "Expected day names from #{inspect(AshWorkflow.WallClock.day_names())}, got: #{inspect(day)}"}
    end
  end

  def validate_days(other),
    do:
      {:error, "Expected a non-empty list of day names like [:mon, :fri], got: #{inspect(other)}"}

  def validate_time_zone(value) when is_binary(value), do: {:ok, value}
  def validate_time_zone(value) when is_atom(value) and not is_nil(value), do: {:ok, value}

  def validate_time_zone(other) do
    {:error,
     "Expected an attribute name like :candidate_time_zone, or a literal zone like " <>
       "\"Australia/Sydney\", got: #{inspect(other)}"}
  end

  @doc """
  The wall-clock schedule this `every` declares, or `nil` when it measures an
  `interval` instead.

  `on` defaults to every day, so an `every` naming only `at` and `time_zone`
  fires daily.
  """
  @spec wall_clock(t()) :: AshWorkflow.WallClock.t() | nil
  def wall_clock(%__MODULE__{at: nil}), do: nil

  def wall_clock(%__MODULE__{at: at, on: on, time_zone: time_zone, interval: interval}) do
    {:ok, days} = AshWorkflow.WallClock.to_day_numbers(on || AshWorkflow.WallClock.day_names())

    %AshWorkflow.WallClock{time: at, days: days, time_zone: time_zone, stride: stride(interval)}
  end

  # An `interval` alongside `at` is a count of local days between fires, not a
  # duration. `AshWorkflow.Verifiers.ValidateEvery` rejects any other unit, but
  # transformers run before verifiers, so an unusable unit falls through as no
  # stride at all rather than raising ahead of the error that explains it.
  defp stride({value, :days}), do: value
  defp stride(_interval), do: nil

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
