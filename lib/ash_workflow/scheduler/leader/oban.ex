defmodule AshWorkflow.Scheduler.Leader.Oban do
  @moduledoc """
  Borrows leadership from `Oban.Peer.leader?/2`.

  Oban already elects one node per instance to run cluster-singleton work, and
  `Oban.Stager` gates on the same answer. `Oban.Peer` documents this use: "you
  can use peer leadership to extend Oban with custom plugins, or even within
  your own application."

  Nothing on Oban's job side runs. `AshWorkflow.Scheduler.Precise` arms its own
  timers and calls `AshWorkflow.Scheduler.execute/3` directly, so no queue
  runs, no worker is defined, and no `Oban.Job` row is written.

  ## Options

    * `:name` — the Oban instance to ask. Defaults to `Oban`.
    * `:timeout` — how long to wait for the peer to answer, in milliseconds.
      Defaults to 5000, which is `Oban.Peer.leader?/2`'s own default.

  ## An application that runs no jobs

  Start an instance that holds only the peer:

      {Oban, name: AshWorkflow.Peer, repo: MyApp.Repo, queues: [], plugins: [], stager: false}

  Then select it:

      scheduler {AshWorkflow.Scheduler.Precise, leader: {AshWorkflow.Scheduler.Leader.Oban, name: AshWorkflow.Peer}}

  Three things about that configuration are traps.

  Pass `plugins: []`, never `plugins: false`. `Oban.Config` replaces the peer
  with `Oban.Peers.Isolated` set to `leader?: false` when `plugins` is `false`,
  so that instance would never lead and nothing would ever arm a timer.

  `testing: :manual` and `testing: :inline` make the same substitution. Under
  test this implementation therefore always answers `false`, which is why
  `AshWorkflow.Scheduler.Leader.Single` is the default and what a test should
  select.

  `Oban.Peers.Database` needs the `oban_peers` table and a running
  `Oban.Notifier` under the instance name, because it listens for a departing
  leader to stand down. Oban's migrations are a requirement even with no
  queues, and the peer module cannot be started on its own.

  A distinct instance name takes its own row in `oban_peers`, so it never
  contends with the application's main Oban leadership. The two may elect
  different nodes, which is fine: exactly one node must arm timers, not the
  same one Oban picked.
  """
  @behaviour AshWorkflow.Scheduler.Leader

  @default_name Oban
  @default_timeout 5_000

  @impl AshWorkflow.Scheduler.Leader
  def leader?(opts) do
    name = Keyword.get(opts, :name, @default_name)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Oban.Peer.leader?(name, timeout)
  end
end
