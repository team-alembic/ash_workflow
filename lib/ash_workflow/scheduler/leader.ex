defmodule AshWorkflow.Scheduler.Leader do
  @moduledoc """
  Answers whether this node is the one that should arm timers.

  `AshWorkflow.Scheduler.Precise` holds its deadlines in memory. Two nodes
  holding the same timer fire the same deadline twice, so exactly one node may
  arm them. This behaviour is how `Precise` asks which node that is, and it is
  one callback so that a deployment can answer the question with whatever it
  already runs.

  ## The implementations

  * `AshWorkflow.Scheduler.Leader.Single` — always the leader. The default,
    correct on one node, and what every test wants.
  * `AshWorkflow.Scheduler.Leader.Oban` — delegates to `Oban.Peer.leader?/2`,
    which is the same election `Oban.Stager` gates on. Correct across a
    cluster, and needs an Oban instance running.

  ## Choosing one

      workflow do
        scheduler {AshWorkflow.Scheduler.Precise, leader: AshWorkflow.Scheduler.Leader.Oban}
      end

  Or with options for the implementation:

      scheduler {AshWorkflow.Scheduler.Precise, leader: {AshWorkflow.Scheduler.Leader.Oban, name: MyApp.Oban}}

  `Single` is the default because a workflow running on one node should not have
  to configure an election to get a timer. `Precise` logs a warning at boot when
  it is running on `Single` and more than one node is connected, since that is
  the configuration where deadlines fire twice.
  """

  @doc """
  Whether this node should arm timers.

  Called before arming a deadline and again before firing one. An
  implementation that talks to the network must not raise: return `false` when
  it cannot tell, so that a poll picks the work up rather than two nodes racing.
  """
  @callback leader?(opts :: keyword()) :: boolean()

  @default AshWorkflow.Scheduler.Leader.Single

  @doc false
  # Normalizes the `leader` option to {module, opts}, the same shape
  # `AshWorkflow.Scheduler.validate/1` produces for the scheduler itself.
  @spec normalize(module() | {module(), keyword()} | nil) :: {module(), keyword()}
  def normalize(nil), do: {@default, []}
  def normalize(module) when is_atom(module), do: {module, []}
  def normalize({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}

  @doc """
  Ask the configured leader implementation whether this node should arm timers.

  A raising implementation answers `false`. Losing a deadline to the polled
  fallback is recoverable; crashing the process that holds every other timer is
  not.
  """
  @spec leader?({module(), keyword()}) :: boolean()
  def leader?({module, opts}) do
    module.leader?(opts)
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end
