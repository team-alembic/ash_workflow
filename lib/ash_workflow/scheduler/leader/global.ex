defmodule AshWorkflow.Scheduler.Leader.Global do
  @moduledoc """
  Elects one node through `:global.set_lock/3`, using distributed Erlang alone.

  `AshWorkflow.Scheduler.Leader.Oban` is the better answer wherever Oban runs,
  because `Oban.Peer` is hardened and its lease survives a node that dies
  without saying goodbye. This exists for a deployment that clusters but runs
  no Oban, which is exactly what a workflow selecting
  `AshWorkflow.Scheduler.Precise` may have: nothing else in the tree needs a
  queue.

  ## Selecting it

      scheduler {AshWorkflow.Scheduler.Precise, leader: AshWorkflow.Scheduler.Leader.Global}

  Or, when the timeline is started directly:

      {AshWorkflow.Scheduler.Precise.Timeline,
       resources: [MyApp.Order], leader: AshWorkflow.Scheduler.Leader.Global}

  ## Options

    * `:id` — the lock's resource id. Defaults to this module, which is right
      unless one cluster runs two independent timelines that must each elect a
      leader of their own.

  ## How the lock behaves

  `:global.set_lock/3` with zero retries either takes the lock or returns
  immediately, so a node that does not hold it answers `false` and arms
  nothing. The lock is held by the calling process, which is the timeline
  itself, so `:global` releases it when that process dies and another node
  takes it on its next check. Nothing has to time out for leadership to move.

  Two things follow from `:global` rather than from this module.

  A node that is not connected to the cluster believes it holds the lock,
  because `:global` only knows the nodes it can see. Both halves of a network
  partition therefore arm timers, and both sides fire. `Oban.Peers.Database`
  does not have this property, because the lease lives in the database both
  halves share, which is the reason to prefer `Leader.Oban` when there is a
  database to lean on.

  Distributed Erlang has to be running. On one node with no distribution,
  `Node.self/0` is `:nonode@nohost`, `:global` still grants the lock, and this
  answers exactly what `AshWorkflow.Scheduler.Leader.Single` answers, through a
  cluster-wide lock that has no other node to exclude.
  """
  @behaviour AshWorkflow.Scheduler.Leader

  @impl AshWorkflow.Scheduler.Leader
  def leader?(opts) do
    id = Keyword.get(opts, :id, __MODULE__)

    # The lock is keyed by {id, self()} rather than by {id, node()} so that a
    # restarted timeline on the same node takes a lock its dead predecessor
    # cannot still be holding.
    :global.set_lock({id, self()}, [Node.self() | Node.list()], 0)
  end
end
