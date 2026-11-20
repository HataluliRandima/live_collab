defmodule LiveCollab.Integration.LifecycleTest do
  @moduledoc """
  LiveView lifecycle against a real Phoenix.Presence / Phoenix.PubSub stack:
  mount, join/leave, reconnect, re-track, untrack and process exit.
  """
  use LiveCollab.CollabCase, async: true

  @alice %{id: "alice", name: "Alice Liddell"}
  @bob %{id: "bob", name: "Bob Builder"}

  describe "mount" do
    test "connected mount tracks the LiveView process in Presence" do
      doc = unique_doc()
      view = join(doc, @alice)

      assert %{"alice" => %{metas: [meta]}} = presence_list(doc)
      assert meta.client_id == assigns(view).collab_client_id
      assert meta.user_name == "Alice Liddell"
      assert assigns(view).collab_topic == topic_for(doc)
      assert [%{id: "alice", tabs_count: 1}] = assigns(view).collab_users
    end

    test "disconnected (static) render does not track or subscribe" do
      doc = unique_doc()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"user" => @alice})
        |> get("/doc/#{doc}")

      assert html_response(conn, 200) =~ "users-count"
      assert presence_list(doc) == %{}
    end

    test "client ids are server generated and unique per LiveView" do
      doc = unique_doc()
      v1 = join(doc, @alice)
      v2 = join(doc, @alice)

      id1 = assigns(v1).collab_client_id
      id2 = assigns(v2).collab_client_id
      assert id1 =~ ~r/\Acli_[A-Za-z0-9_-]{16}\z/
      refute id1 == id2
    end
  end

  describe "joining and leaving" do
    test "collaborators see each other join and leave" do
      doc = unique_doc()
      alice = join(doc, @alice)
      bob = join(doc, @bob)

      eventually(fn -> length(assigns(alice).collab_users) == 2 end)
      assert Enum.map(assigns(bob).collab_users, & &1.id) == ["alice", "bob"]

      bob_client = assigns(bob).collab_client_id
      GenServer.stop(bob.pid, :normal)

      eventually(fn -> length(assigns(alice).collab_users) == 1 end)
      # Peers are told which clients left so cursors/selections can be removed.
      assert_push_event(alice, "live_collab:peers_left", %{client_ids: [^bob_client]})
    end

    test "multiple tabs of the same user are consolidated" do
      doc = unique_doc()
      tab1 = join(doc, @alice)
      _tab2 = join(doc, @alice)

      eventually(fn ->
        match?([%{id: "alice", tabs_count: 2}], assigns(tab1).collab_users)
      end)
    end

    test "a burst of joins converges on every LiveView" do
      doc = unique_doc()
      # LiveViewTest helpers must run in the test process, so mounts are issued
      # back-to-back; Presence propagation to the 20 LiveViews is concurrent.
      views = for i <- 1..20, do: join(doc, %{id: "u#{i}", name: "User #{i}"})

      for view <- views do
        eventually(fn -> length(assigns(view).collab_users) == 20 end)
      end
    end

    test "a crashed LiveView's presence, locks and activity are purged" do
      doc = unique_doc()
      alice = join(doc, @alice)
      bob = join(doc, @bob)

      render_hook(bob, "live_collab:field_focus", %{"field" => "title"})
      render_hook(bob, "live_collab:element_active", %{"element" => "row:1"})
      eventually(fn -> Map.has_key?(assigns(alice).collab_locks, "title") end)
      eventually(fn -> Map.has_key?(assigns(alice).collab_activities, "row:1") end)

      Process.unlink(bob.proxy |> elem(2))
      Process.exit(bob.pid, :kill)

      eventually(fn -> assigns(alice).collab_locks == %{} end)
      assert assigns(alice).collab_activities == %{}
      assert Map.keys(presence_list(doc)) == ["alice"]
    end
  end

  describe "local presence replica" do
    test "every LiveView's replica converges to the real Presence state after churn" do
      # LiveViews rebuild from diffs applied to a local replica instead of calling
      # Presence.list/1 on every change; this checks the replica stays correct.
      doc = unique_doc()
      views = for i <- 1..8, do: join(doc, %{id: "u#{rem(i, 5)}", name: "User #{i}"})
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..60 do
        view = Enum.random(views)

        case :rand.uniform(4) do
          1 ->
            render_hook(view, "live_collab:field_focus", %{"field" => "f#{:rand.uniform(3)}"})

          2 ->
            render_hook(view, "live_collab:field_blur", %{})

          3 ->
            render_hook(view, "live_collab:element_active", %{
              "element" => "row:#{:rand.uniform(3)}"
            })

          4 ->
            render_hook(view, "live_collab:element_inactive", %{})
        end
      end

      {leaving, staying} = Enum.split(views, 3)
      Enum.each(leaving, &GenServer.stop(&1.pid, :normal))
      _late = join(doc, %{id: "late", name: "Late"})

      normalize = fn entries ->
        for {key, %{metas: metas}} <- entries, into: %{} do
          {key, metas |> Enum.map(&Map.drop(&1, [:phx_ref_prev])) |> Enum.sort_by(& &1.phx_ref)}
        end
      end

      for view <- staying do
        eventually(fn ->
          normalize.(socket(view).private.live_collab.entries) == normalize.(presence_list(doc))
        end)
      end
    end
  end

  describe "re-tracking" do
    test "tracking the same resource again is idempotent" do
      doc = unique_doc()
      view = join(doc, @alice)
      client_id = assigns(view).collab_client_id

      render_click(view, "retrack", %{"id" => doc})

      assert assigns(view).collab_client_id == client_id
      assert %{"alice" => %{metas: [_single]}} = presence_list(doc)
    end

    test "tracking another resource leaves the previous topic cleanly" do
      doc1 = unique_doc()
      doc2 = unique_doc()
      view = join(doc1, @alice)
      peer = join(doc1, @bob)
      render_hook(view, "live_collab:field_focus", %{"field" => "title"})

      render_click(view, "retrack", %{"id" => doc2})

      assert presence_list(doc1) |> Map.keys() == ["bob"]
      assert presence_list(doc2) |> Map.keys() == ["alice"]
      assert assigns(view).collab_topic == topic_for(doc2)
      assert assigns(view).collab_editing_field == nil
      eventually(fn -> assigns(peer).collab_locks == %{} end)

      # Events on the new topic work (hooks were not attached twice).
      render_hook(view, "live_collab:field_focus", %{"field" => "body"})
      assert %{"body" => _lock} = LiveCollab.Field.extract_locks(presence_list(doc2))
    end
  end

  describe "stale messages after untrack / re-track" do
    # Messages for the previous topic can already be in the mailbox when the
    # LiveView unsubscribes. They must be absorbed, not routed to the app's
    # handle_info/2 (the test LiveView has no clause for them and would crash).
    test "regression: in-flight messages for the old topic are absorbed after re-track" do
      doc1 = unique_doc()
      view = join(doc1, @alice)
      render_click(view, "retrack", %{"id" => unique_doc()})

      old = topic_for(doc1)
      send(view.pid, %Phoenix.Socket.Broadcast{topic: old, event: "presence_diff", payload: %{}})
      send(view.pid, {:collab_cursor_moved, old, %{client_id: "cli_x", x: 0.1, y: 0.1}})
      send(view.pid, {:live_collab_sync, old})

      assert assigns(view).collab_topic != old
      assert Process.alive?(view.pid)
    end

    test "regression: in-flight messages are absorbed after untrack" do
      doc = unique_doc()
      view = join(doc, @alice)
      render_click(view, "untrack", %{})

      send(view.pid, %Phoenix.Socket.Broadcast{topic: topic_for(doc), event: "presence_diff"})
      send(view.pid, {:collab_spotlight_status, topic_for(doc), %{active: true}})

      assert assigns(view).collab_topic == nil
      assert Process.alive?(view.pid)
    end
  end

  describe "untrack" do
    test "removes presence and halts late client events without crashing" do
      doc = unique_doc()
      view = join(doc, @alice)

      render_click(view, "untrack", %{})

      assert presence_list(doc) == %{}
      assert assigns(view).collab_topic == nil

      # Client hooks may still fire; they must be absorbed, not routed to the
      # application's handle_event/3 (which has no clause for them).
      render_hook(view, "live_collab:field_focus", %{"field" => "title"})
      render_hook(view, "live_collab:cursor_move", %{"x" => 0.5, "y" => 0.5})
      assert Process.alive?(view.pid)
      assert presence_list(doc) == %{}
    end

    test "can track again after untrack" do
      doc = unique_doc()
      view = join(doc, @alice)

      render_click(view, "untrack", %{})
      render_click(view, "retrack", %{"id" => doc})

      assert Map.keys(presence_list(doc)) == ["alice"]
      render_hook(view, "live_collab:field_focus", %{"field" => "title"})
      assert assigns(view).collab_editing_field == "title"
    end
  end

  describe "coexistence with application callbacks" do
    test "application events and messages pass through LiveCollab's hooks" do
      doc = unique_doc()
      view = join(doc, @alice)

      render_hook(view, "app_event", %{"n" => 1})
      send(view.pid, {:app_message, :hello})

      assert [{:info, :hello}, %{"n" => 1}] = assigns(view).app_events
    end
  end
end
