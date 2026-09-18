defmodule AshWorkflow.Entities.Repeat do
  @moduledoc """
  Declares that a timeout re-fires, and optionally when it should stop.

  A timeout that declares `repeat` fires every `fire_after` interval for as
  long as the record stays in the step, rather than once. Two spellings, and
  they mean the same thing when no bound is given:

      repeat true

      repeat do
        until {8, :days}
      end

  ## How repeating works, and why the bound needs its own anchor

  A repeat re-arms itself by resetting `state_entered_at` after each firing,
  which restarts the `fire_after` window. That reset is the whole mechanism.

  It is also why `until` cannot be measured against the timeout's `field`
  (`state_entered_at` by default). Repeating is what keeps pushing that
  timestamp forward, so a bound checked against it would never be reached.

  `until` is measured against `field` on this entity instead, which defaults to
  `repeat_started_at` — an attribute `AshWorkflow.Transformers.AddAttributes`
  adds when some timeout declares `until` and no anchor of its own. Every
  genuine step entry writes it alongside `state_entered_at`, and no repeat
  firing touches it, so it answers "when did the record enter this step"
  without the resets `state_entered_at` cannot avoid.

  ## Anchoring the bound somewhere else

  `field` names a different datetime attribute to measure `until` from, for a
  bound that is about the record rather than about this step:

      # Nag while the record sits here, but give up a year after signup
      repeat do
        until {365, :days}
        field :created_at
      end

  The anchor must be a datetime attribute or expression calculation that the
  repeat does not itself reset, which is why `state_entered_at` is rejected.
  `AshWorkflow.Verifiers.ValidateTimeoutFields` checks both.
  """

  defstruct [:until, :field, enabled?: true, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          until: AshWorkflow.Duration.t() | nil,
          field: atom() | nil
        }

  @schema [
    enabled?: [
      type: :boolean,
      default: true,
      doc: """
      Whether the timeout repeats. Defaults to `true`, since declaring `repeat`
      at all is the point. `repeat false` is the same as declaring no `repeat`,
      and exists so that turning one off is a one-word edit.
      """
    ],
    until: [
      type: {:custom, AshWorkflow.Duration, :validate, []},
      doc: """
      Stop repeating once this much wall-clock time has passed since `field`.

      Measured against `field` on this entity, never against the timeout's own
      `field`, which repeating keeps moving forward. Must be strictly longer
      than the timeout's `fire_after`, since equal to it leaves no room to fire
      even once.
      """
    ],
    field: [
      type: :atom,
      doc: """
      The datetime attribute or expression calculation to measure `until`
      against. Defaults to `repeat_started_at`, which the extension adds and
      maintains. Name another to bound the repeat against a fact about the
      record, such as `:created_at`.
      """
    ]
  ]

  def attribute_schema, do: @schema

  @doc """
  The attribute `until` is measured against when the repeat names no `field`.
  """
  @spec default_field() :: atom()
  def default_field, do: :repeat_started_at

  @doc """
  The anchor this repeat measures `until` against.
  """
  @spec anchor_field(t()) :: atom()
  def anchor_field(%__MODULE__{field: nil}), do: default_field()
  def anchor_field(%__MODULE__{field: field}), do: field
end
