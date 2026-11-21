# Cost of one collaboration-state rebuild for a room of N collaborators.
#
# Every LiveView in a room performs this rebuild when Presence changes, so the
# cost of one Presence change across the whole room is roughly N x this figure.
#
#     mix run bench/presence_rebuild.exs
#
# Uses only public functions (extract_users/1, extract_locks/2,
# extract_activities/1), so it runs unchanged against earlier versions.

alias LiveCollab.{Element, Field, Presence}

build_room = fn n ->
  for i <- 1..n, into: %{} do
    key = "user_#{i}"

    meta = %{
      client_id: "cli_#{i}",
      user_id: key,
      user_name: "User #{i}",
      user_avatar: nil,
      user_color: "#4F46E5",
      # ~10% editing a field (with some contention), ~20% active on an element
      field: if(rem(i, 10) == 0, do: "field_#{rem(i, 37)}", else: nil),
      acquired_at: 1_700_000_000_000 + i,
      element: if(rem(i, 5) == 0, do: "row:#{rem(i, 50)}", else: nil),
      element_type: :viewing,
      element_acquired_at: 1_700_000_000_000 + i,
      phx_ref: "ref#{i}"
    }

    {key, %{metas: [meta]}}
  end
end

rebuild = fn entries ->
  {Presence.extract_users(entries), Field.extract_locks(entries, clock_skew_tolerance_ms: 500),
   Element.extract_activities(entries)}
end

label = System.get_env("BENCH_LABEL", "current")

Benchee.run(
  %{"rebuild (users + locks + activities)" => rebuild},
  inputs: for(n <- [10, 100, 500, 1000], into: %{}, do: {"N=#{n}", build_room.(n)}),
  time: 3,
  warmup: 1,
  memory_time: 1,
  formatters: [Benchee.Formatters.Console],
  save: [path: "bench/results/presence_rebuild_#{label}.benchee", tag: label]
)
