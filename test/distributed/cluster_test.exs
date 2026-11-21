defmodule LiveCollab.Distributed.ClusterTest do
  @moduledoc """
  Multi-node behaviour on real BEAM nodes started with `:peer`.

  What is verified here is what LiveCollab actually guarantees across a cluster:
  presence replication, *eventual* agreement on lock winners, convergence after
  a network partition heals, and cleanup/recovery after node failure. These are
  Phoenix.Tracker (CRDT) properties combined with LiveCollab's deterministic
  conflict resolution; there is no distributed mutual exclusion.

  Run with: mix test --include distributed
  Requires epmd (`epmd -daemon`).
  """
  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag timeout: 120_000

  alias LiveCollab.Test.ClusterNode

  # Fast gossip so tests converge quickly. down_period must be >= 2 * broadcast_period.
  @tracker_opts [broadcast_period: 25, down_period: 400, permdown_period: 2_000, log_level: false]

  setup do
    {_, 0} = System.cmd("epmd", ["-daemon"])
    suffix = System.unique_integer([:positive])
    {p1, n1} = start_peer(:"lc_a_#{suffix}")
    {p2, n2} = start_peer(:"lc_b_#{suffix}")
    connect(p1, n2)
    topic = "live_collab:cluster:#{suffix}"
    %{p1: p1, n1: n1, p2: p2, n2: n2, topic: topic}
  end

  test "presence tracked on one node becomes visible on the other", ctx do
    _alice = client(ctx.p1, ctx.topic, "alice")
    _bob = client(ctx.p2, ctx.topic, "bob")

    eventually(fn -> keys(ctx.p1, ctx.topic) == ["alice", "bob"] end)
    eventually(fn -> keys(ctx.p2, ctx.topic) == ["alice", "bob"] end)
  end

  test "concurrent claims on different nodes converge to the same winner", ctx do
    alice = client(ctx.p1, ctx.topic, "alice")
    bob = client(ctx.p2, ctx.topic, "bob")
    eventually(fn -> keys(ctx.p1, ctx.topic) == ["alice", "bob"] end)

    # Both claim before either claim has replicated.
    {:ok, _} = cmd(ctx.p1, alice, {:focus, "total"})
    {:ok, _} = cmd(ctx.p2, bob, {:focus, "total"})

    eventually(fn ->
      w1 = winner(ctx.p1, ctx.topic, "total")
      w2 = winner(ctx.p2, ctx.topic, "total")
      w1 != nil and w1 == w2 and both_claims_visible?(ctx)
    end)
  end

  test "a partition lets both sides hold the lock; healing converges on one winner", ctx do
    alice = client(ctx.p1, ctx.topic, "alice")
    bob = client(ctx.p2, ctx.topic, "bob")
    eventually(fn -> keys(ctx.p2, ctx.topic) == ["alice", "bob"] end)

    partition(ctx.p1, ctx.n2)
    eventually(fn -> keys(ctx.p1, ctx.topic) == ["alice"] end)
    eventually(fn -> keys(ctx.p2, ctx.topic) == ["bob"] end)

    # Split brain: each side grants the lock to its local collaborator.
    # Bob's clock is "earlier" (models skew larger than the tolerance window).
    {:ok, _} = cmd(ctx.p1, alice, {:claim_at, "title", 1_700_000_005_000})
    {:ok, _} = cmd(ctx.p2, bob, {:claim_at, "title", 1_700_000_001_000})
    assert winner(ctx.p1, ctx.topic, "title") == "cli_alice"
    assert winner(ctx.p2, ctx.topic, "title") == "cli_bob"

    connect(ctx.p1, ctx.n2)

    eventually(fn ->
      winner(ctx.p1, ctx.topic, "title") == "cli_bob" and
        winner(ctx.p2, ctx.topic, "title") == "cli_bob"
    end)
  end

  test "claims inside the same tolerance window break ties by client id on every node", ctx do
    alice = client(ctx.p1, ctx.topic, "alice")
    bob = client(ctx.p2, ctx.topic, "bob")
    eventually(fn -> keys(ctx.p1, ctx.topic) == ["alice", "bob"] end)

    # 120ms apart but in the same 500ms window: cli_alice < cli_bob wins,
    # even though Bob's claim is earlier.
    {:ok, _} = cmd(ctx.p1, alice, {:claim_at, "notes", 1_700_000_000_480})
    {:ok, _} = cmd(ctx.p2, bob, {:claim_at, "notes", 1_700_000_000_360})

    eventually(fn ->
      winner(ctx.p1, ctx.topic, "notes") == "cli_alice" and
        winner(ctx.p2, ctx.topic, "notes") == "cli_alice"
    end)
  end

  test "a failed node's collaborators and locks are removed; a restarted node rejoins", ctx do
    alice = client(ctx.p1, ctx.topic, "alice")
    bob = client(ctx.p2, ctx.topic, "bob")
    {:ok, _} = cmd(ctx.p2, bob, {:focus, "title"})
    eventually(fn -> winner(ctx.p1, ctx.topic, "title") == "cli_bob" end)

    # Hard node failure.
    :peer.stop(ctx.p2)

    eventually(fn -> keys(ctx.p1, ctx.topic) == ["alice"] end, 5_000)
    assert ClusterNode |> call(ctx.p1, :locks, [ctx.topic]) == %{}
    {:ok, _} = cmd(ctx.p1, alice, {:focus, "title"})
    assert winner(ctx.p1, ctx.topic, "title") == "cli_alice"

    # Recovery: a fresh node with the same name joins and replicates.
    {p2b, n2b} =
      start_peer(ctx.n2 |> Atom.to_string() |> String.split("@") |> hd() |> String.to_atom())

    assert n2b == ctx.n2
    connect(ctx.p1, n2b)
    _bob2 = client(p2b, ctx.topic, "bob")

    eventually(fn -> keys(ctx.p1, ctx.topic) == ["alice", "bob"] end, 5_000)
    eventually(fn -> winner(p2b, ctx.topic, "title") == "cli_alice" end, 5_000)
  end

  # --- helpers ---------------------------------------------------------------

  defp start_peer(name) do
    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        connection: :standard_io,
        args: [~c"-kernel", ~c"dist_auto_connect", ~c"never", ~c"-setcookie", ~c"live_collab"]
      })

    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
    :ok = :peer.call(peer, ClusterNode, :boot, [@tracker_opts])
    on_exit(fn -> catch_exit(:peer.stop(peer)) end)
    {peer, node}
  end

  defp connect(peer, node), do: true = :peer.call(peer, :net_kernel, :connect_node, [node])

  defp partition(peer, node) do
    true = :peer.call(peer, :erlang, :disconnect_node, [node])
  end

  defp client(peer, topic, id) do
    call(ClusterNode, peer, :start_client, [
      topic,
      %{id: id, name: String.capitalize(id)},
      "cli_#{id}"
    ])
  end

  defp cmd(peer, pid, command), do: call(ClusterNode, peer, :command, [pid, command])

  defp keys(peer, topic), do: call(ClusterNode, peer, :keys, [topic])

  defp winner(peer, topic, field) do
    get_in(call(ClusterNode, peer, :locks, [topic]), [field, :client_id])
  end

  defp both_claims_visible?(ctx) do
    metas = fn peer ->
      :peer.call(peer, LiveCollab.Test.ClusterPresence, :list, [ctx.topic])
      |> Enum.flat_map(fn {_k, %{metas: m}} -> m end)
      |> Enum.count(&(&1.field == "total"))
    end

    metas.(ctx.p1) == 2 and metas.(ctx.p2) == 2
  end

  defp call(mod, peer, fun, args), do: :peer.call(peer, mod, fun, args)

  defp eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("cluster did not converge before timeout")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end
end
