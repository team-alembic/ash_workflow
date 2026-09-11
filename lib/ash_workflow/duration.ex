defmodule AshWorkflow.Duration do
  @moduledoc """
  The duration tuple a `timeout` measures with `after` and a `retry` block
  waits with `backoff`.

  It exists so both read the same tuple: `{3, :days}`, `{10, :seconds}`.
  """

  @type unit :: :seconds | :minutes | :hours | :days
  @type t :: {pos_integer(), unit()}

  @doc """
  Validates a duration tuple, for use as a Spark `{:custom, ...}` schema type.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate({value, unit})
      when is_integer(value) and value > 0 and unit in [:seconds, :minutes, :hours, :days] do
    {:ok, {value, unit}}
  end

  def validate(other) do
    {:error, "Expected a duration tuple like {3, :days}, got: #{inspect(other)}"}
  end

  @doc """
  Converts a duration to milliseconds.
  """
  @spec to_milliseconds(t()) :: pos_integer()
  def to_milliseconds({value, :seconds}), do: value * 1_000
  def to_milliseconds({value, :minutes}), do: value * 60_000
  def to_milliseconds({value, :hours}), do: value * 3_600_000
  def to_milliseconds({value, :days}), do: value * 86_400_000

  @doc """
  Converts a duration to seconds.
  """
  @spec to_seconds(t()) :: pos_integer()
  def to_seconds({value, :seconds}), do: value
  def to_seconds({value, :minutes}), do: value * 60
  def to_seconds({value, :hours}), do: value * 3_600
  def to_seconds({value, :days}), do: value * 86_400
end
