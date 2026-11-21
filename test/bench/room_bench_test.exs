defmodule LiveCollab.Bench.RoomBenchTest do
  @moduledoc """
  End-to-end room benchmark with real LiveView processes, Phoenix.Presence and
  Phoenix.PubSub on a single node. Not part of the default suite.

      BENCH_SIZES=10,100,500,1000 mix test test/bench --include benchmark

  Only public API is used (LiveCollab.track/4 via the test LiveView and
  `live_collab:*` client events), so the same file can be run against older
  versions for before/after comparisons. Results are printed and written to
  bench/results/room_<label>.json (label from BENCH_LABEL, default "current").

  Scenarios, per room size N:

    * join storm - N LiveViews mount one after another into one room. Measures
      wall time until every LiveView sees N collaborators, and the reductions
      (BEAM work units, a CPU proxy) and memory of all LiveView processes.
    * cursor fan-out - one collaborator sends 50 cursor moves; measures the time
      until all 50 * (N - 1) push_events reached the clients, and the reductions
      spent by the sender and by the receivers.

  Caveat: LiveViewTest routes every client's push_events to this one test
  process, so the fan-out figure includes that single-process bottleneck. Treat
  absolute numbers as relative indicators, not production capacity.
  """
  use LiveCollab.CollabCase, async: false

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @cursor_events 50

  test "room scaling" do
    sizes =
      (System.get_env("BENCH_SIZES") || "10,100,500,1000")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer/1)

    label = System.get_env("BENCH_LABEL", "current")
    deadline_ms = String.to_integer(System.get_env("BENCH_JOIN_TIMEOUT_MS", "600000"))

    results =
      for n <- sizes do
        result = run_room(n, deadline_ms)
        IO.puts(format_row(label, result))
        result
      end

    File.mkdir_p!("bench/results")

    File.write!(
      "bench/results/room_#{label}.json",
      Jason.encode!(
        %{
          label: label,
          otp: System.otp_release(),
          elixir: System.version(),
          schedulers: System.schedulers_online(),
          results: results
        },
        pretty: true
      )
    )
  end

  defp run_room(n, deadline_ms) do
    doc = unique_doc()
    :erlang.garbage_collect()

    {join_us, {views, converged?}} =
      :timer.tc(fn ->
        views = for i <- 1..n, do: join(doc, %{id: "u#{i}", name: "User #{i}"})
        {views, converge(views, n, deadline_ms)}
      end)

    pids = Enum.map(views, & &1.pid)
    after_join = stats(pids)

    fanout =
      if converged? do
        cursor_fanout(views, n)
      else
        %{
          fanout_ms: nil,
          deliveries_per_sec: nil,
          sender_reductions: nil,
          receiver_reductions: nil
        }
      end

    final = stats(pids)
    Enum.each(views, &GenServer.stop(&1.pid, :normal))

    Map.merge(
      %{
        n: n,
        join_converged: converged?,
        join_ms: div(join_us, 1000),
        join_reductions: after_join.reductions,
        lv_memory_mb: Float.round(final.memory / 1_048_576, 2),
        lv_memory_kb_per_client: Float.round(final.memory / 1024 / n, 1),
        max_message_queue: final.max_queue
      },
      fanout
    )
  end

  defp converge(views, n, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Enum.all?(views, fn view ->
      wait(fn -> length(assigns(view).collab_users) == n end, deadline)
    end)
  end

  defp wait(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(5) && wait(fun, deadline)
    end
  end

  defp cursor_fanout([sender | receivers] = views, n) do
    pids = Enum.map(views, & &1.pid)
    # Drain push_events produced while joining (e.g. live_collab:init).
    flush()
    before = Map.new(pids, &{&1, reductions(&1)})
    expected = @cursor_events * (n - 1)

    {us, received} =
      :timer.tc(fn ->
        for i <- 1..@cursor_events do
          render_hook(sender, "live_collab:cursor_move", %{"x" => i / 100, "y" => 0.5})
        end

        count_pushes("live_collab:cursor_moved", expected, 0)
      end)

    true = received == expected
    sender_red = reductions(sender.pid) - before[sender.pid]

    receiver_red =
      receivers |> Enum.map(&(reductions(&1.pid) - before[&1.pid])) |> Enum.sum()

    %{
      fanout_ms: Float.round(us / 1000, 1),
      deliveries: expected,
      deliveries_per_sec: if(us > 0, do: round(expected / (us / 1_000_000)), else: nil),
      sender_reductions: sender_red,
      receiver_reductions_per_client: if(n > 1, do: div(receiver_red, n - 1), else: 0)
    }
  end

  # LiveViewTest delivers push_events to the test process as {ref, {:push_event, e, p}}.
  # Matching on the shape here keeps this file runnable against any version.
  defp count_pushes(_event, expected, expected), do: expected

  defp count_pushes(event, expected, acc) do
    receive do
      {_ref, {:push_event, ^event, _payload}} -> count_pushes(event, expected, acc + 1)
      {_ref, {:push_event, _other, _payload}} -> count_pushes(event, expected, acc)
    after
      30_000 -> acc
    end
  end

  defp flush do
    receive do
      {_ref, {:push_event, _, _}} -> flush()
    after
      100 -> :ok
    end
  end

  defp reductions(pid) do
    case Process.info(pid, :reductions) do
      {:reductions, r} -> r
      nil -> 0
    end
  end

  # Memory is measured after a GC so it reflects retained state, not garbage.
  defp stats(pids) do
    Enum.each(pids, &:erlang.garbage_collect/1)

    infos =
      pids
      |> Enum.map(&Process.info(&1, [:reductions, :memory, :message_queue_len]))
      |> Enum.reject(&is_nil/1)

    %{
      reductions: infos |> Enum.map(& &1[:reductions]) |> Enum.sum(),
      memory: infos |> Enum.map(& &1[:memory]) |> Enum.sum(),
      max_queue: infos |> Enum.map(& &1[:message_queue_len]) |> Enum.max(fn -> 0 end)
    }
  end

  defp format_row(label, r) do
    "[#{label}] N=#{r.n} join=#{r.join_ms}ms converged=#{r.join_converged} " <>
      "join_reductions=#{r.join_reductions} fanout=#{inspect(r.fanout_ms)}ms " <>
      "deliveries/s=#{inspect(r.deliveries_per_sec)} sender_reductions=#{inspect(r.sender_reductions)} " <>
      "recv_reductions/client=#{inspect(r[:receiver_reductions_per_client])} " <>
      "lv_mem=#{r.lv_memory_mb}MB (#{r.lv_memory_kb_per_client}KB/client)"
  end
end
