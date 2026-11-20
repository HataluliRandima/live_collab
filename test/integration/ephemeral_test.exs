defmodule LiveCollab.Integration.EphemeralTest do
  @moduledoc """
  High-frequency ephemeral events (cursor, viewport, selection): relay semantics
  and the "no re-render" property, measured on real LiveView processes.
  """
  use LiveCollab.CollabCase, async: true

  @alice %{id: "alice", name: "Alice", color: "#DC2626"}
  @bob %{id: "bob", name: "Bob"}

  setup do
    doc = unique_doc()
    alice = join(doc, @alice)
    bob = join(doc, @bob)
    carol = join(doc, %{id: "carol", name: "Carol"})
    for v <- [alice, bob, carol], do: eventually(fn -> length(assigns(v).collab_users) == 3 end)
    %{doc: doc, alice: alice, bob: bob, carol: carol}
  end

  test "cursor moves reach every peer but never echo to the sender", ctx do
    alice_id = assigns(ctx.alice).collab_client_id

    render_hook(ctx.alice, "live_collab:cursor_move", %{
      "x" => 0.123456,
      "y" => "0.5",
      "container_id" => "board"
    })

    for peer <- [ctx.bob, ctx.carol] do
      assert_push_event(peer, "live_collab:cursor_moved", %{
        client_id: ^alice_id,
        x: 0.1235,
        y: 0.5,
        container_id: "board",
        user_name: "Alice",
        user_color: "#DC2626"
      })
    end

    refute_push_event(ctx.alice, "live_collab:cursor_moved", _, 20)
  end

  test "cursor_left, viewport and selection events are relayed", ctx do
    render_hook(ctx.alice, "live_collab:cursor_left", %{"container_id" => "board"})
    assert_push_event(ctx.bob, "live_collab:cursor_left", %{container_id: "board"})

    render_hook(ctx.alice, "live_collab:viewport_move", %{
      "scroll_x" => 0.25,
      "scroll_y" => 0.75,
      "anchor_element_id" => "section-2"
    })

    assert_push_event(ctx.bob, "live_collab:viewport_moved", %{
      scroll_x: 0.25,
      scroll_y: 0.75,
      zoom: 1.0,
      anchor_element_id: "section-2"
    })

    render_hook(ctx.alice, "live_collab:selection_move", %{
      "x" => 0.1,
      "y" => 0.2,
      "width" => 0.3,
      "height" => 0.4,
      "selected_ids" => ["card-1", "card-2"]
    })

    assert_push_event(ctx.bob, "live_collab:selection_moved", %{
      width: 0.3,
      selected_ids: ["card-1", "card-2"]
    })

    render_hook(ctx.alice, "live_collab:selection_clear", %{})
    assert_push_event(ctx.bob, "live_collab:selection_cleared", %{})
  end

  test "ephemeral events never trigger a re-render on sender or receivers", ctx do
    # The README promises "zero assigns diffing" for Path 2 events. Previously
    # every cursor event re-assigned the rate limiter, so the *sender* re-rendered
    # on every mouse move. The limiter now lives in socket.private.
    before = Enum.map([ctx.alice, ctx.bob, ctx.carol], &render_count/1)

    for i <- 1..25 do
      render_hook(ctx.alice, "live_collab:cursor_move", %{"x" => i / 100, "y" => 0.5})

      render_hook(ctx.bob, "live_collab:viewport_move", %{
        "scroll_x" => 0.1,
        "scroll_y" => i / 100
      })
    end

    for _ <- 1..25, do: assert_push_event(ctx.carol, "live_collab:cursor_moved", _)

    after_counts = Enum.map([ctx.alice, ctx.bob, ctx.carol], &render_count/1)
    assert after_counts == before
  end

  test "element activity is shared, deduplicated per user and cleared on inactive", ctx do
    render_hook(ctx.alice, "live_collab:element_active", %{
      "element" => "row:7",
      "type" => "selected"
    })

    render_hook(ctx.bob, "live_collab:element_active", %{"element" => "row:7"})

    eventually(fn -> length(Map.get(assigns(ctx.carol).collab_activities, "row:7", [])) == 2 end)

    types = assigns(ctx.carol).collab_activities["row:7"] |> Map.new(&{&1.user_id, &1.type})
    assert types == %{"alice" => :selected, "bob" => :viewing}

    # A stale "inactive" for another element is ignored.
    render_hook(ctx.alice, "live_collab:element_inactive", %{"element" => "row:8"})
    render_hook(ctx.bob, "live_collab:element_inactive", %{"element" => "row:7"})

    eventually(fn ->
      match?([%{user_id: "alice"}], Map.get(assigns(ctx.carol).collab_activities, "row:7"))
    end)
  end

  test "editing a field upgrades the element activity to :editing", ctx do
    render_hook(ctx.alice, "live_collab:element_active", %{"element" => "row:1"})
    render_hook(ctx.alice, "live_collab:field_focus", %{"field" => "row.1.qty"})

    eventually(fn ->
      match?([%{type: :editing}], Map.get(assigns(ctx.bob).collab_activities, "row:1"))
    end)
  end

  test "bursts of presence diffs are coalesced into fewer rebuilds", ctx do
    capture_telemetry(ctx.carol, [[:live_collab, :presence, :sync]])
    carol_id = assigns(ctx.carol).collab_client_id

    # Freeze Carol's LiveView so diffs pile up in its mailbox, then release it.
    :sys.suspend(ctx.carol.pid)

    for i <- 1..10 do
      render_hook(ctx.alice, "live_collab:field_focus", %{"field" => "f#{i}"})
    end

    render_hook(ctx.bob, "live_collab:element_active", %{"element" => "row:1"})
    # Give Phoenix.Presence time to fan the diffs out into Carol's mailbox.
    eventually(fn -> elem(Process.info(ctx.carol.pid, :message_queue_len), 1) >= 5 end)
    :sys.resume(ctx.carol.pid)

    eventually(fn -> assigns(ctx.carol).collab_locks |> Map.keys() == ["f10"] end)

    syncs =
      collect_syncs(carol_id)
      |> Enum.map(fn {measurements, _meta} -> measurements end)

    total_diffs = Enum.sum(Enum.map(syncs, &(&1.coalesced_diffs + 1)))
    assert total_diffs >= 5
    assert length(syncs) < total_diffs
  end

  defp collect_syncs(client_id, acc \\ []) do
    receive do
      {:telemetry, [:live_collab, :presence, :sync], m, %{client_id: ^client_id} = meta} ->
        collect_syncs(client_id, [{m, meta} | acc])

      {:telemetry, [:live_collab, :presence, :sync], _m, _meta} ->
        collect_syncs(client_id, acc)
    after
      50 -> Enum.reverse(acc)
    end
  end
end
