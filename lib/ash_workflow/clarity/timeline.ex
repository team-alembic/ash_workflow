defmodule AshWorkflow.Clarity.Timeline do
  @moduledoc false

  # What happens to a record in one step, ordered by how long after it entered
  # the step. A moment is either a fixed offset from `state_entered_at` or a
  # deadline read from a field on the record, which no chart can place on a
  # shared axis.

  alias AshWorkflow.Charts.Format
  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Retry
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
  alias AshWorkflow.Info
  alias AshWorkflow.Scheduler

  # How many firings of an unbounded `every` to list before summarising.
  @every_firings 3

  defmodule Event do
    @moduledoc false
    defstruct [:at, :kind, :text]

    @type at :: {:offset, non_neg_integer()} | {:anchor, String.t()}
    @type t :: %__MODULE__{at: at(), kind: atom(), text: String.t()}
  end

  defmodule Moment do
    @moduledoc false
    defstruct [:at, :label, events: []]

    @type t :: %__MODULE__{at: Event.at(), label: String.t(), events: [Event.t()]}
  end

  @type t :: %{
          step: atom(),
          moments: [Moment.t()],
          lag: String.t() | nil,
          leaves_by: Event.at() | :caller | :never
        }

  @doc """
  The timeline of `step_name`. `lag` names how late the scheduler may run a
  deadline, or is `nil` for a scheduler that arms a timer per deadline.
  `leaves_by` is the latest moment a record is still in the step: a fixed
  offset or field deadline when a timeout moves it on, `:caller` when only a
  transition does, and `:never` for a terminal step.
  """
  @spec step(Ash.Resource.t(), atom()) :: t()
  def step(resource, step_name) do
    step = Info.step(resource, step_name)
    floor_ms = resource |> Info.scheduler() |> Scheduler.precision_floor_ms()
    lag = if floor_ms > 1_000, do: humanize(floor_ms)
    exit = earliest_exit(step)

    events =
      entry_events(resource, step, lag) ++
        retry_events(step) ++
        timeout_events(step) ++
        every_events(step, exit) ++
        undo_events(resource, step)

    %{
      step: step.name,
      moments: events |> reachable(exit) |> moments(),
      lag: lag,
      leaves_by: leaves_by(step, exit)
    }
  end

  @doc """
  An offset in milliseconds as words, such as `1 minute 30 seconds`.
  """
  @spec humanize(non_neg_integer()) :: String.t()
  def humanize(0), do: "0 seconds"

  def humanize(ms) do
    [days: 86_400_000, hours: 3_600_000, minutes: 60_000, seconds: 1_000]
    |> Enum.reduce({ms, []}, fn {unit, size}, {left, parts} ->
      case div(left, size) do
        0 -> {left, parts}
        count -> {rem(left, size), [Format.duration({count, unit}) | parts]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  defp entry_events(_resource, %Step{} = step, lag) do
    cond do
      Step.terminal?(step) ->
        [event(0, :terminal, "the workflow ends here")]

      step.action ->
        [event(0, :runs, run_text(step, lag)) | on_success_events(step)]

      step.transitions != [] ->
        names = Enum.map(step.transitions, & &1.name)
        [event(0, :opens, "callers can run " <> sentence(names))]

      true ->
        [event(0, :waits, "nothing runs and no caller can move the record")]
    end
  end

  defp run_text(step, nil), do: "#{step.action} runs"
  defp run_text(step, lag), do: "#{step.action} runs at the next poll, within #{lag}"

  defp on_success_events(%Step{on_success: []}), do: []

  defp on_success_events(%Step{on_success: routes}) do
    targets = routes |> Enum.map(& &1.to) |> Enum.uniq()
    [event(0, :moves, "when it succeeds the record moves to " <> sentence(targets, "or"))]
  end

  defp retry_events(%Step{action: nil}), do: []

  defp retry_events(%Step{retry: retry} = step) do
    retry = retry || %Retry{}

    {events, last_offset} =
      Enum.map_reduce(2..retry.max_attempts//1, 0, fn attempt, offset ->
        offset = offset + Retry.delay_ms(retry, attempt - 1)
        text = "attempt #{attempt} of #{retry.max_attempts} if attempt #{attempt - 1} failed"
        {event(offset, :retries, text), offset}
      end)

    events ++ on_error_events(step, last_offset, retry.max_attempts)
  end

  defp on_error_events(%Step{on_error: nil}, _offset, _attempts), do: []

  defp on_error_events(%Step{on_error: on_error}, offset, 1),
    do: [event(offset, :moves, "if it fails the record moves to #{on_error}")]

  defp on_error_events(%Step{on_error: on_error}, offset, _attempts),
    do: [event(offset, :moves, "if every attempt fails the record moves to #{on_error}")]

  defp timeout_events(%Step{timeouts: timeouts} = step) do
    for timeout <- timeouts do
      effect =
        if timeout.transition_to,
          do: "moves the record to #{timeout.transition_to}" <> closes_transitions(step),
          else: "runs #{timeout.action}"

      %Event{
        at: timeout_at(timeout),
        kind: if(timeout.transition_to, do: :moves, else: :runs),
        text: "#{timeout.name} #{effect}" <> retried(timeout.retry) <> self_scheduled(timeout)
      }
    end
  end

  defp timeout_at(%Timeout{fire_at: field}) when not is_nil(field), do: {:anchor, "at #{field}"}

  defp timeout_at(%Timeout{fire_after: fire_after} = timeout) do
    case Timeout.deadline_field(timeout) do
      :state_entered_at -> {:offset, AshWorkflow.Duration.to_milliseconds(fire_after)}
      field -> {:anchor, "#{Format.duration(fire_after)} after #{field}"}
    end
  end

  defp closes_transitions(%Step{transitions: []}), do: ""

  defp closes_transitions(%Step{transitions: transitions}) do
    ", after which #{transitions |> Enum.map(& &1.name) |> sentence("or")} can no longer run"
  end

  defp retried(retry) do
    case Format.retry(retry) do
      nil -> ""
      text -> ", retried as #{text}"
    end
  end

  defp self_scheduled(%Timeout{self_scheduled?: true}), do: ", when the application triggers it"
  defp self_scheduled(_timeout), do: ""

  defp every_events(%Step{everys: everys}, exit_ms),
    do: Enum.flat_map(everys, &firings(&1, exit_ms))

  # An `every` fires until its `until`, or until a timeout moves the record on.
  # With neither, the first few firings stand for the rest.
  defp firings(%Every{interval: interval, until: until} = every, exit_ms) do
    interval_ms = AshWorkflow.Duration.to_milliseconds(interval)
    until_ms = until && AshWorkflow.Duration.to_milliseconds(until)
    text = "#{every.name} runs #{every.action}" <> retried(every.retry)

    case Enum.reject([until_ms, exit_ms], &is_nil/1) do
      [] ->
        Enum.map(1..(@every_firings - 1)//1, &event(&1 * interval_ms, :repeats, text)) ++
          [
            event(
              @every_firings * interval_ms,
              :repeats,
              text <> ", and every #{Format.duration(interval)} after"
            )
          ]

      bounds ->
        bound_ms = Enum.min(bounds)
        count = div(bound_ms - 1, interval_ms)

        stop =
          if until_ms == bound_ms, do: [event(until_ms, :closes, "#{every.name} stops")], else: []

        Enum.map(1..count//1, &event(&1 * interval_ms, :repeats, text)) ++ stop
    end
  end

  defp undo_events(resource, step) do
    case Info.undo(resource) do
      nil ->
        []

      undo ->
        froms = for {from, to} <- Info.undoable_edges(resource), to == step.name, do: from

        undo_window(undo, Enum.uniq(froms))
    end
  end

  defp undo_window(_undo, []), do: []

  defp undo_window(undo, froms) do
    text = "undo can return the record to " <> sentence(froms, "or")

    case undo.within do
      nil ->
        [event(0, :undo, text)]

      within ->
        [event(0, :undo, text), event(window_ms(within), :closes, "the undo window closes")]
    end
  end

  defp window_ms(within), do: AshWorkflow.Duration.to_milliseconds(within)

  # The earliest fixed offset at which a timeout always moves the record on.
  # Nothing after it can happen in this step.
  defp earliest_exit(%Step{timeouts: timeouts}) do
    timeouts
    |> Enum.filter(& &1.transition_to)
    |> Enum.map(&timeout_at/1)
    |> Enum.flat_map(fn
      {:offset, ms} -> [ms]
      _anchor -> []
    end)
    |> Enum.min(fn -> nil end)
  end

  defp reachable(events, nil), do: events

  defp reachable(events, exit_ms) do
    Enum.filter(events, fn
      %Event{at: {:offset, ms}} -> ms <= exit_ms
      _anchored -> true
    end)
  end

  defp leaves_by(step, exit_ms) do
    anchored_exit =
      Enum.find_value(step.timeouts, fn timeout ->
        with true <- timeout.transition_to != nil,
             {:anchor, _} = at <- timeout_at(timeout),
             do: at
      end)

    cond do
      Step.terminal?(step) -> :never
      exit_ms -> {:offset, exit_ms}
      anchored_exit -> anchored_exit
      step.action -> {:offset, retry_total_ms(step.retry || %Retry{})}
      true -> :caller
    end
  end

  defp retry_total_ms(retry) do
    Enum.reduce(1..(retry.max_attempts - 1)//1, 0, &(&2 + Retry.delay_ms(retry, &1)))
  end

  defp moments(events) do
    {fixed, anchored} = Enum.split_with(events, &match?({:offset, _}, &1.at))

    fixed_moments =
      fixed
      |> Enum.group_by(& &1.at)
      |> Enum.sort_by(fn {{:offset, ms}, _events} -> ms end)
      |> Enum.map(fn {at, events} -> %Moment{at: at, label: label(at), events: events} end)

    anchored_moments =
      anchored
      |> Enum.chunk_by(& &1.at)
      |> Enum.map(fn [%{at: at} | _] = events ->
        %Moment{at: at, label: label(at), events: events}
      end)

    fixed_moments ++ anchored_moments
  end

  @doc """
  The latest a record stays in the step, as words.
  """
  @spec leaves_by_text(t(), Step.t()) :: String.t()
  def leaves_by_text(%{leaves_by: :never}, _step), do: "never, the workflow ends here"
  def leaves_by_text(%{leaves_by: :caller}, _step), do: "only when a caller runs a transition"

  def leaves_by_text(%{leaves_by: {:offset, ms}, lag: lag}, %Step{action: action})
      when not is_nil(action) do
    retries = if ms > 0, do: ", or #{humanize(ms)} later once retries run out", else: ""
    poll = if lag, do: " (it starts within #{lag})", else: ""
    "when #{action} finishes#{poll}#{retries}"
  end

  def leaves_by_text(%{leaves_by: {:anchor, "at " <> field}}, step),
    do: "by #{field}" <> sooner(step)

  def leaves_by_text(%{leaves_by: {:anchor, text}}, step), do: "by " <> text <> sooner(step)

  def leaves_by_text(%{leaves_by: {:offset, ms}, lag: nil}, step),
    do: "within #{humanize(ms)}" <> sooner(step)

  def leaves_by_text(%{leaves_by: {:offset, ms}, lag: lag}, step),
    do: "within #{humanize(ms)}, up to #{lag} more" <> sooner(step)

  defp sooner(%Step{transitions: []}), do: ""
  defp sooner(_step), do: ", or sooner when a caller runs a transition"

  @doc """
  The words for when a moment happens: `on entry`, `after 30 minutes`, or a
  field deadline such as `at offer_expires_at`.
  """
  @spec label(Event.at()) :: String.t()
  def label({:offset, 0}), do: "on entry"
  def label({:offset, ms}), do: "after " <> humanize(ms)
  def label({:anchor, text}), do: text

  defp event(offset, kind, text), do: %Event{at: {:offset, offset}, kind: kind, text: text}

  defp sentence(names, word \\ "and")
  defp sentence([only], _word), do: to_string(only)

  defp sentence(names, word) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " #{word} " <> to_string(last)
  end
end
