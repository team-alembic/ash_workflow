defmodule AshWorkflow.Entities.Retry do
  @moduledoc """
  Defines the failure policy for a step's or timeout's generated work.

  `AshWorkflow.Scheduler.Precise` computes its own retry delay from this
  struct, through `delay_ms/2`. `AshWorkflow.Scheduler.Oban` instead converts
  `backoff` to the seconds ash_oban's trigger expects and hands that to
  `Transformer.build_entity!(AshOban, ...)`, and lets Oban do the waiting.
  """

  defstruct max_attempts: 1, backoff: :exponential, __spark_metadata__: nil

  @type backoff :: AshWorkflow.Duration.t() | :exponential

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff: backoff()
        }

  @schema [
    max_attempts: [
      type: :pos_integer,
      default: 1,
      doc: """
      How many times the scheduler runs the step's action before it gives up.

      The default of 1 means one attempt and no retry, which is why a step
      declaring `on_error` moves to its error state on the first failure.
      """
    ],
    backoff: [
      type: {:or, [{:custom, AshWorkflow.Duration, :validate, []}, {:literal, :exponential}]},
      default: :exponential,
      doc: """
      How long to wait between attempts. A duration tuple such as
      `{10, :seconds}` is a fixed delay between attempts. `:exponential` grows
      the delay with the attempt number.

      Has no effect while `max_attempts` is 1.
      """
    ]
  ]

  def attribute_schema, do: @schema

  @doc """
  The delay in milliseconds before attempt number `attempt + 1`, given the
  attempt number that just failed (1-based).

  A fixed duration backoff is the same delay regardless of attempt.
  `:exponential` uses Oban's default worker backoff formula, so
  `AshWorkflow.Scheduler.Precise` and `AshWorkflow.Scheduler.Oban` agree on
  timing: `trunc(:math.pow(attempt, 4) + 15) * 1000`. This has no jitter, so
  the delay is deterministic and testable.
  """
  @spec delay_ms(t(), pos_integer()) :: non_neg_integer()
  def delay_ms(%__MODULE__{backoff: {_value, _unit} = duration}, _attempt) do
    AshWorkflow.Duration.to_milliseconds(duration)
  end

  def delay_ms(%__MODULE__{backoff: :exponential}, attempt) do
    trunc(:math.pow(attempt, 4) + 15) * 1000
  end
end
