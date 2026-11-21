defmodule LiveCollab.Integration.SecurityTest do
  @moduledoc """
  Security regression tests. Every value sent by a client is untrusted; these
  tests drive real LiveViews with hostile payloads and assert on what peers
  receive and on what is written to Presence.
  """
  use LiveCollab.CollabCase, async: true

  @alice %{id: "alice", name: "Alice"}
  @bob %{id: "bob", name: "Bob"}

  defp pair(opts \\ []) do
    doc = unique_doc()
    alice = join(doc, Keyword.get(opts, :alice, @alice), Keyword.get(opts, :alice_opts, []))
    bob = join(doc, Keyword.get(opts, :bob, @bob), Keyword.get(opts, :bob_opts, []))
    eventually(fn -> length(assigns(alice).collab_users) == 2 end)
    {doc, alice, bob}
  end

  describe "identity spoofing" do
    test "client-supplied client_id, user id, name and color are ignored" do
      {_doc, alice, bob} = pair()
      alice_id = assigns(alice).collab_client_id
      bob_id = assigns(bob).collab_client_id

      render_hook(alice, "live_collab:cursor_move", %{
        "x" => 0.5,
        "y" => 0.5,
        "client_id" => bob_id,
        "user_id" => "bob",
        "user_name" => "Bob",
        "user_color" => "red;background:url(//evil)"
      })

      assert_push_event(bob, "live_collab:cursor_moved", payload)
      assert payload.client_id == alice_id
      assert payload.user_id == "alice"
      assert payload.user_name == "Alice"
      assert payload.user_color =~ ~r/\A#[0-9A-Fa-f]{6}\z/
    end

    test "a spoofed client_id cannot release someone else's lock" do
      {doc, alice, bob} = pair()
      alice_id = assigns(alice).collab_client_id

      render_hook(alice, "live_collab:field_focus", %{"field" => "title"})
      render_hook(bob, "live_collab:field_blur", %{"field" => "title", "client_id" => alice_id})

      assert %{"title" => %{client_id: ^alice_id}} =
               LiveCollab.Field.extract_locks(presence_list(doc))
    end
  end

  describe "untrusted display data" do
    test "unsafe user colors and avatar URLs never reach Presence" do
      user = %{
        id: "mallory",
        name: "<img src=x onerror=alert(1)>",
        color: "#fff; background-image: url(https://evil.example/track)",
        avatar_url: "javascript:alert(1)"
      }

      doc = unique_doc()
      view = join(doc, user)

      assert %{metas: [meta]} = presence_list(doc)["mallory"]
      assert meta.user_color =~ ~r/\A#[0-9A-F]{6}\z/
      assert meta.user_avatar == nil
      # Names are data, not markup: they are kept verbatim and escaped on render.
      assert meta.user_name == user.name
      refute render(view) =~ "<img src=x"
    end

    test "short hex colors are normalized to #rrggbb (the JS appends alpha suffixes)" do
      doc = unique_doc()
      _view = join(doc, %{id: "c", name: "C", color: "#0af"})
      assert %{metas: [%{user_color: "#00aaff"}]} = presence_list(doc)["c"]
    end
  end

  describe "payload validation" do
    test "field and element ids with markup, traversal or oversize are rejected" do
      {doc, alice, _bob} = pair()
      capture_telemetry(alice, [[:live_collab, :event, :rejected]])

      for bad <- [
            "<script>alert(1)</script>",
            "../../etc/passwd",
            "a\u0000b",
            String.duplicate("a", 256),
            %{"nested" => "map"},
            ["list"],
            ""
          ] do
        render_hook(alice, "live_collab:field_focus", %{"field" => bad})
        render_hook(alice, "live_collab:element_active", %{"element" => bad})
      end

      assert LiveCollab.Field.extract_locks(presence_list(doc)) == %{}
      assert LiveCollab.Element.extract_activities(presence_list(doc)) == %{}

      assert_received {:telemetry, [:live_collab, :event, :rejected], %{count: 1},
                       %{event: "field_focus", reason: :disallowed_characters}}

      assert_received {:telemetry, [:live_collab, :event, :rejected], _,
                       %{event: "field_focus", reason: :field_id_too_long}}
    end

    test "invalid container ids are rejected and not relayed" do
      {_doc, alice, bob} = pair()

      for container <- ["<svg onload=alert(1)>", String.duplicate("c", 300), %{}, 42] do
        render_hook(alice, "live_collab:cursor_move", %{
          "x" => 0.1,
          "y" => 0.1,
          "container_id" => container
        })
      end

      refute_push_event(bob, "live_collab:cursor_moved", _payload, 50)
    end

    test "non-numeric, out of range and oversized coordinates are rejected" do
      {_doc, alice, bob} = pair()

      for {x, y} <- [{"NaN", 0.5}, {1.0e300, 0.5}, {0.5, %{}}, {String.duplicate("1", 64), 0.5}] do
        render_hook(alice, "live_collab:cursor_move", %{"x" => x, "y" => y})
      end

      render_hook(alice, "live_collab:viewport_move", %{
        "scroll_x" => 0.5,
        "scroll_y" => 0.5,
        "zoom" => 1_000
      })

      render_hook(alice, "live_collab:selection_move", %{
        "x" => 0.1,
        "y" => 0.1,
        "width" => -5,
        "height" => 1
      })

      refute_push_event(bob, "live_collab:cursor_moved", _payload, 20)
      refute_push_event(bob, "live_collab:viewport_moved", _payload, 20)
      refute_push_event(bob, "live_collab:selection_moved", _payload, 20)
    end

    test "oversized selections are bounded before being relayed" do
      {_doc, alice, bob} = pair()

      ids =
        [String.duplicate("x", 10_000), 123, nil] ++ Enum.map(1..5_000, &"node_#{&1}")

      render_hook(alice, "live_collab:selection_move", %{
        "x" => 0.1,
        "y" => 0.1,
        "width" => 0.2,
        "height" => 0.2,
        "selected_ids" => ids
      })

      assert_push_event(bob, "live_collab:selection_moved", %{selected_ids: relayed})
      assert length(relayed) == 100
      assert Enum.all?(relayed, &(is_binary(&1) and byte_size(&1) <= 255))
    end

    test "malformed and unknown live_collab events are absorbed, never crash" do
      {_doc, alice, _bob} = pair()
      capture_telemetry(alice, [[:live_collab, :event, :rejected]])

      render_hook(alice, "live_collab:cursor_move", %{})
      render_hook(alice, "live_collab:field_focus", %{"nope" => 1})
      render_hook(alice, "live_collab:drop_tables", %{"x" => 1})

      assert Process.alive?(alice.pid)

      assert_received {:telemetry, _, _, %{event: "cursor_move", reason: :invalid_params}}
      assert_received {:telemetry, _, _, %{event: "field_focus", reason: :invalid_params}}
      assert_received {:telemetry, _, _, %{event: "drop_tables", reason: :unknown_event}}
    end
  end

  describe "spotlight authorization" do
    test "a viewer cannot lead a presentation" do
      {_doc, viewer, bob} = pair(alice: %{id: "v", name: "Viewer", role: "viewer"})
      capture_telemetry(viewer, [[:live_collab, :spotlight, :unauthorized]])

      render_hook(viewer, "live_collab:spotlight_lead", %{})

      assert_push_event(viewer, "live_collab:spotlight_unauthorized", %{reason: "unauthorized"})
      refute_push_event(bob, "live_collab:spotlight_status", _payload, 50)
      assert assigns(bob).collab_spotlight_leader == nil
      assert_received {:telemetry, _, _, %{action: :lead}}
    end

    test "collab_can_present? false on the socket denies leading" do
      {_doc, alice, bob} = pair(alice_opts: [assigns: %{collab_can_present?: false}])
      render_hook(alice, "live_collab:spotlight_lead", %{})
      refute_push_event(bob, "live_collab:spotlight_status", _payload, 50)
    end

    test "an authorized presenter leads; peers are notified and track the leader" do
      {_doc, alice, bob} = pair()
      alice_id = assigns(alice).collab_client_id

      render_hook(alice, "live_collab:spotlight_lead", %{})

      assert_push_event(bob, "live_collab:spotlight_status", %{active: true, client_id: ^alice_id})

      assert assigns(bob).collab_spotlight_leader == alice_id
    end

    test "regression: a viewer cannot stop a presentation it does not know about" do
      # Previously can_stop_spotlight?/3 returned true whenever the local leader
      # was nil — e.g. for a viewer who joined after the presentation started —
      # letting any late joiner broadcast a stop to every follower.
      doc = unique_doc()
      alice = join(doc, @alice)
      bob = join(doc, @bob)
      render_hook(alice, "live_collab:spotlight_lead", %{})
      assert_push_event(bob, "live_collab:spotlight_status", %{active: true})

      late_viewer = join(doc, %{id: "late", name: "Late", role: "viewer"})
      render_hook(late_viewer, "live_collab:spotlight_stop", %{})

      refute_push_event(bob, "live_collab:spotlight_status", %{active: false}, 50)
      assert assigns(bob).collab_spotlight_leader == assigns(alice).collab_client_id
    end

    test "a viewer that knows the leader still cannot stop it" do
      {_doc, alice, viewer} = pair(bob: %{id: "v", name: "Viewer", role: "viewer"})
      render_hook(alice, "live_collab:spotlight_lead", %{})
      assert_push_event(viewer, "live_collab:spotlight_status", %{active: true})

      render_hook(viewer, "live_collab:spotlight_stop", %{})

      assert_push_event(viewer, "live_collab:spotlight_unauthorized", _)
      refute_push_event(alice, "live_collab:spotlight_status", %{active: false}, 50)
    end

    test "a co-presenter can stop the presentation and the leader is told" do
      {_doc, alice, bob} = pair()
      alice_id = assigns(alice).collab_client_id
      render_hook(alice, "live_collab:spotlight_lead", %{})
      assert_push_event(bob, "live_collab:spotlight_status", %{active: true})

      render_hook(bob, "live_collab:spotlight_stop", %{})

      assert_push_event(alice, "live_collab:spotlight_status", %{
        active: false,
        client_id: ^alice_id
      })

      assert assigns(alice).collab_spotlight_leader == nil
    end

    test "when the presenter disconnects, followers are released" do
      {_doc, alice, bob} = pair()
      alice_id = assigns(alice).collab_client_id
      render_hook(alice, "live_collab:spotlight_lead", %{})
      assert_push_event(bob, "live_collab:spotlight_status", %{active: true})

      GenServer.stop(alice.pid, :normal)

      assert_push_event(
        bob,
        "live_collab:spotlight_status",
        %{active: false, client_id: ^alice_id},
        1_000
      )

      assert assigns(bob).collab_spotlight_leader == nil
    end
  end

  describe "rate limiting" do
    @limited [collab_opts: [telemetry_rate_per_sec: 1, telemetry_burst_limit: 5]]

    test "telemetry floods are cut off at the burst limit" do
      doc = unique_doc()
      alice = join(doc, @alice, @limited)
      bob = join(doc, @bob)
      eventually(fn -> length(assigns(alice).collab_users) == 2 end)
      capture_telemetry(alice, [[:live_collab, :event, :rate_limited]])

      for i <- 1..50 do
        render_hook(alice, "live_collab:cursor_move", %{"x" => i / 100, "y" => 0.5})
      end

      for _ <- 1..5, do: assert_push_event(bob, "live_collab:cursor_moved", _)
      refute_push_event(bob, "live_collab:cursor_moved", _, 50)

      assert_received {:telemetry, _, %{count: 1},
                       %{event: "cursor_move", bucket: :telemetry, consecutive: 1}}
    end

    test "events that were not rate limited before (cursor_left, spotlight) are now limited" do
      doc = unique_doc()
      alice = join(doc, @alice, @limited)
      bob = join(doc, @bob)
      eventually(fn -> length(assigns(alice).collab_users) == 2 end)

      for _ <- 1..50, do: render_hook(alice, "live_collab:cursor_left", %{})

      for _ <- 1..5, do: assert_push_event(bob, "live_collab:cursor_left", _)
      refute_push_event(bob, "live_collab:cursor_left", _, 50)
    end

    test "presence writes have their own, separate bucket" do
      doc = unique_doc()

      alice =
        join(doc, @alice, collab_opts: [presence_rate_per_sec: 1, presence_burst_limit: 3])

      capture_telemetry(alice, [[:live_collab, :lock, :claimed]])

      for i <- 1..20 do
        render_hook(alice, "live_collab:field_focus", %{"field" => "f#{i}"})
      end

      for _ <- 1..3, do: assert_received({:telemetry, [:live_collab, :lock, :claimed], _, _})
      refute_received {:telemetry, [:live_collab, :lock, :claimed], _, _}

      # Releases are never rate limited.
      render_hook(alice, "live_collab:field_blur", %{})
      assert LiveCollab.Field.extract_locks(presence_list(doc)) == %{}
    end

    test "the bucket replenishes over time" do
      doc = unique_doc()

      alice =
        join(doc, @alice, collab_opts: [telemetry_rate_per_sec: 20, telemetry_burst_limit: 2])

      bob = join(doc, @bob)
      eventually(fn -> length(assigns(alice).collab_users) == 2 end)

      # Exhaust the bucket. Refill (20/s) can add a token while the flood is being
      # sent on a slow machine, so assert the flood was cut rather than an exact count.
      for _ <- 1..30, do: render_hook(alice, "live_collab:cursor_move", %{"x" => 0.1, "y" => 0.1})

      delivered =
        Enum.count(1..30, fn _ -> push_received?(bob, "live_collab:cursor_moved", 0) end)

      assert delivered >= 2 and delivered < 30

      # 20 tokens/s: a token is back within ~50ms.
      eventually(fn ->
        render_hook(alice, "live_collab:cursor_move", %{"x" => 0.2, "y" => 0.2})
        push_received?(bob, "live_collab:cursor_moved", 5)
      end)
    end
  end
end
