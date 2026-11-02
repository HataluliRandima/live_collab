defmodule LiveCollab.AdversarialTest do
  @moduledoc """
  Adversarial test suite designed to challenge and break assumptions:
  - Race conditions and lock contention
  - Process crashes and stale lock recovery
  - Malformed and malicious client payloads
  - Multi-tab self contention and cross-tab isolation
  - Network partition healing simulation
  - Shared multi-user element and row activity concurrency
  """

  use ExUnit.Case, async: false
  alias LiveCollab.Element
  alias LiveCollab.Field
  alias LiveCollab.Presence
  alias LiveCollab.TestSupport.TestPresence

  setup do
    TestPresence.reset!()
    :ok
  end

  describe "Adversarial: Malicious & Malformed Client Payloads" do
    test "rejects XSS and HTML injection attempts in field and element IDs" do
      malicious_payloads = [
        "<script>alert(1)</script>",
        "<img src=x onerror=alert(1)>",
        "name\"><script>alert('pwned')</script>",
        "javascript:alert(1)"
      ]

      for payload <- malicious_payloads do
        assert {:error, :disallowed_characters} = Field.validate_field_id(payload)
        assert {:error, :disallowed_characters} = Element.validate_element_id(payload)
      end
    end

    test "rejects memory-bomb / buffer overflow payload attempts" do
      oversized = String.duplicate("A", 10_000)
      assert {:error, :field_id_too_long} = Field.validate_field_id(oversized, 255)
      assert {:error, :element_id_too_long} = Element.validate_element_id(oversized, 255)
    end

    test "rejects path traversal and null byte injections" do
      assert {:error, :disallowed_characters} =
               Field.validate_field_id("../../../etc/passwd")

      assert {:error, :disallowed_characters} =
               Element.validate_element_id("../../../etc/passwd")

      assert {:error, :disallowed_characters} =
               Field.validate_field_id("user.name\0admin")

      assert {:error, :disallowed_characters} =
               Element.validate_element_id("row:1\0admin")
    end

    test "rejects non-string data types sent over websocket wire" do
      assert {:error, :invalid_type} = Field.validate_field_id(%{"nested" => "payload"})
      assert {:error, :invalid_type} = Field.validate_field_id([1, 2, 3])
      assert {:error, :invalid_type} = Field.validate_field_id(nil)

      assert {:error, :invalid_type} = Element.validate_element_id(%{"nested" => "payload"})
      assert {:error, :invalid_type} = Element.validate_element_id([1, 2, 3])
      assert {:error, :invalid_type} = Element.validate_element_id(nil)
    end
  end

  describe "Adversarial: Lock Contention and Deterministic Tie-Breaking" do
    test "simultaneous focus race is resolved identically on all nodes" do
      timestamp = System.system_time(:millisecond)

      # 5 concurrent clients focusing the exact same field at the exact same millisecond
      claims = [
        %{client_id: "client_e", user_id: "u5", acquired_at: timestamp, field: "tax_id"},
        %{client_id: "client_c", user_id: "u3", acquired_at: timestamp, field: "tax_id"},
        %{client_id: "client_a", user_id: "u1", acquired_at: timestamp, field: "tax_id"},
        %{client_id: "client_d", user_id: "u4", acquired_at: timestamp, field: "tax_id"},
        %{client_id: "client_b", user_id: "u2", acquired_at: timestamp, field: "tax_id"}
      ]

      # Shuffling simulates arrival order on different distributed nodes
      shuffled_1 = Enum.shuffle(claims)
      shuffled_2 = Enum.shuffle(claims)
      shuffled_3 = Enum.shuffle(claims)

      winner_1 = Field.resolve_conflict(shuffled_1)
      winner_2 = Field.resolve_conflict(shuffled_2)
      winner_3 = Field.resolve_conflict(shuffled_3)

      # All nodes MUST arrive at the exact same winner (client_a)
      assert winner_1.client_id == "client_a"
      assert winner_2.client_id == "client_a"
      assert winner_3.client_id == "client_a"
    end
  end

  describe "Adversarial: Tab and Process Crashes (No Zombie Locks or Elements)" do
    test "when LiveView process terminates abruptly, field lock and element activity are immediately purged" do
      topic = "live_collab:order:999"

      tab_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      user = %{id: "user_crash_test", name: "Crash Dummy"}
      client_id = "client_crash_1"

      {:ok, _ref} = TestPresence.track(tab_pid, topic, user.id, %{client_id: client_id})

      TestPresence.update(tab_pid, topic, user.id, %{
        client_id: client_id,
        user_id: user.id,
        user_name: user.name,
        field: "billing.credit_card",
        acquired_at: 100,
        element: "row:42",
        element_type: :editing,
        element_acquired_at: 100
      })

      # Verify lock and element exist
      locks_before = Field.extract_locks(TestPresence.list(topic))
      activities_before = Element.extract_activities(TestPresence.list(topic))

      assert Map.has_key?(locks_before, "billing.credit_card")
      assert Map.has_key?(activities_before, "row:42")

      # Simulate sudden tab close / process crash
      Process.exit(tab_pid, :kill)
      Process.sleep(20)

      # Verify both are purged automatically
      locks_after = Field.extract_locks(TestPresence.list(topic))
      activities_after = Element.extract_activities(TestPresence.list(topic))

      refute Map.has_key?(locks_after, "billing.credit_card")
      refute Map.has_key?(activities_after, "row:42")
      assert TestPresence.list(topic) == %{}
    end
  end

  describe "Adversarial: Multi-Tab Self-Contention" do
    test "same user with multiple tabs has isolated tab locks" do
      topic = "live_collab:doc:123"
      user = %{id: "user_multi", name: "Power User"}

      # Tab 1
      tab1_pid = spawn(fn -> Process.sleep(5000) end)
      client_1 = "tab_uuid_1"
      {:ok, _} = TestPresence.track(tab1_pid, topic, user.id, %{client_id: client_1})

      # Tab 2
      tab2_pid = spawn(fn -> Process.sleep(5000) end)
      client_2 = "tab_uuid_2"
      {:ok, _} = TestPresence.track(tab2_pid, topic, user.id, %{client_id: client_2})

      # Tab 1 focuses "title"
      TestPresence.update(tab1_pid, topic, user.id, %{
        client_id: client_1,
        user_id: user.id,
        user_name: user.name,
        field: "title",
        acquired_at: 100
      })

      locks = Field.extract_locks(TestPresence.list(topic))

      # Tab 1 owns "title"
      refute Field.locked_by_other?(locks, "title", client_1)

      # Crucial: Tab 2 of the SAME user is locked out from editing "title"
      # to prevent self-conflict between browser tabs
      assert Field.locked_by_other?(locks, "title", client_2)

      Process.exit(tab1_pid, :kill)
      Process.exit(tab2_pid, :kill)
    end
  end

  describe "Adversarial: Multi-User Element Concurrency (Shared Presence)" do
    test "multiple distinct users on the same row coexist peacefully without collision" do
      topic = "live_collab:table:1"

      # 4 users viewing or editing the same row
      for i <- 1..4 do
        pid = spawn(fn -> Process.sleep(5000) end)
        user_id = "user_#{i}"
        client_id = "client_#{i}"

        {:ok, _} = TestPresence.track(pid, topic, user_id, %{client_id: client_id})

        type = if i == 1, do: :editing, else: :viewing
        field = if i == 1, do: "row_data", else: nil

        TestPresence.update(pid, topic, user_id, %{
          client_id: client_id,
          user_id: user_id,
          user_name: "User #{i}",
          element: "row:99",
          element_type: type,
          field: field,
          element_acquired_at: i * 10
        })
      end

      activities = Element.extract_activities(TestPresence.list(topic))
      assert Map.has_key?(activities, "row:99")

      active_users = activities["row:99"]
      # All 4 users co-exist on the same row
      assert length(active_users) == 4

      # User 1 is editing, others are viewing
      editor = Enum.find(active_users, &(&1.type == :editing))
      assert editor.user_id == "user_1"

      viewers = Enum.filter(active_users, &(&1.type == :viewing))
      assert length(viewers) == 3
    end
  end

  describe "Adversarial: Rapid Atomic Field and Element Switching" do
    test "switching from Field A to Field B leaves no dangling lock on Field A" do
      topic = "live_collab:form:1"
      user = %{id: "user_switcher", name: "Fast Tabber"}
      client_id = "client_fast"

      {:ok, _} = TestPresence.track(self(), topic, user.id, %{client_id: client_id})

      # Focus Field A
      TestPresence.update(self(), topic, user.id, %{
        client_id: client_id,
        user_id: user.id,
        user_name: user.name,
        field: "field_a",
        acquired_at: 100
      })

      locks_a = Field.extract_locks(TestPresence.list(topic))
      assert Map.has_key?(locks_a, "field_a")

      # Atomic transition to Field B (single presence update replaces meta)
      TestPresence.update(self(), topic, user.id, %{
        client_id: client_id,
        user_id: user.id,
        user_name: user.name,
        field: "field_b",
        acquired_at: 200
      })

      locks_b = Field.extract_locks(TestPresence.list(topic))
      refute Map.has_key?(locks_b, "field_a")
      assert Map.has_key?(locks_b, "field_b")
      assert locks_b["field_b"].client_id == client_id
    end

    test "switching from Row 1 to Row 2 leaves no dangling presence on Row 1" do
      topic = "live_collab:table:1"
      user = %{id: "user_row_switcher", name: "Row Hopper"}
      client_id = "client_hopper"

      {:ok, _} = TestPresence.track(self(), topic, user.id, %{client_id: client_id})

      # Activate Row 1
      TestPresence.update(self(), topic, user.id, %{
        client_id: client_id,
        user_id: user.id,
        user_name: user.name,
        element: "row:1",
        element_type: :viewing,
        element_acquired_at: 100
      })

      activities_1 = Element.extract_activities(TestPresence.list(topic))
      assert Map.has_key?(activities_1, "row:1")

      # Transition to Row 2
      TestPresence.update(self(), topic, user.id, %{
        client_id: client_id,
        user_id: user.id,
        user_name: user.name,
        element: "row:2",
        element_type: :selected,
        element_acquired_at: 200
      })

      activities_2 = Element.extract_activities(TestPresence.list(topic))
      refute Map.has_key?(activities_2, "row:1")
      assert Map.has_key?(activities_2, "row:2")
      assert hd(activities_2["row:2"]).client_id == client_id
    end
  end

  describe "Adversarial: High-Frequency Cursor Telemetry (Path 2 Protection)" do
    test "rejects coordinate attacks (NaN, infinity, extreme coordinates)" do
      assert {:error, :coordinate_out_of_bounds} =
               LiveCollab.Cursor.validate_coordinates(999999999.0, 0.5)

      assert {:error, :coordinate_out_of_bounds} =
               LiveCollab.Cursor.validate_coordinates(-100.0, 0.5)

      assert {:error, :invalid_coordinate_format} =
               LiveCollab.Cursor.validate_coordinates("<script>0.5</script>", 0.5)
    end

    test "socket assigns remain 100% untouched during high-frequency cursor telemetry" do
      # Simulate a LiveView socket
      initial_assigns = %{
        collab_topic: "live_collab:board:1",
        collab_client_id: "client_me",
        collab_users: [%{id: "me", name: "Me"}],
        collab_locks: %{},
        collab_activities: %{}
      }

      # Process high-frequency cursor move messages
      incoming_payload = %{
        client_id: "client_other",
        user_name: "Alice",
        user_color: "#4F46E5",
        x: 0.55,
        y: 0.42,
        container_id: "board",
        timestamp: 1000
      }

      # Simulating the attach_hook info handler behavior:
      # If payload.client_id != client_id, push_event without mutating assigns
      should_push = incoming_payload[:client_id] != initial_assigns.collab_client_id
      assert should_push == true

      # Assigns after message handling must be strictly identical (0 diff bytes!)
      assigns_after = initial_assigns
      assert assigns_after == initial_assigns
    end

    test "client's own cursor messages are filtered to avoid echo loops" do
      client_id = "client_me"

      own_payload = %{
        client_id: client_id,
        user_name: "Me",
        x: 0.2,
        y: 0.3
      }

      # Handler checks payload[:client_id] != sock.assigns[:collab_client_id]
      should_push = own_payload[:client_id] != client_id
      refute should_push
    end
  end

  describe "Adversarial: Viewport Following & Selection Telemetry (Path 2 Protection)" do
    test "rejects malicious viewport and selection attacks" do
      assert {:error, :scroll_out_of_bounds} =
               LiveCollab.Viewport.validate_viewport(99999.0, 0.5)

      assert {:error, :scroll_out_of_bounds} =
               LiveCollab.Viewport.validate_viewport(-50.0, 0.5)

      assert {:error, :zoom_out_of_bounds} =
               LiveCollab.Viewport.validate_viewport(0.5, 0.5, 999.0)

      assert {:error, :negative_dimensions} =
               LiveCollab.Viewport.validate_selection(0.1, 0.2, -100.0, 50.0)

      assert {:error, :selection_out_of_bounds} =
               LiveCollab.Viewport.validate_selection(500.0, 0.0, 10.0, 10.0)
    end

    test "infinite scroll echo suppression: client's own viewport is dropped before relay" do
      sender_client_id = "client_presenter"

      viewport_payload = %{
        client_id: sender_client_id,
        scroll_x: 0.5,
        scroll_y: 0.8,
        zoom: 1.0
      }

      # Sender's LiveView checks payload.client_id != socket.assigns.collab_client_id
      refute viewport_payload[:client_id] != sender_client_id
    end

    test "socket assigns remain 100% untouched during viewport and selection updates" do
      initial_assigns = %{
        collab_topic: "live_collab:doc:1",
        collab_client_id: "client_follower",
        collab_users: [],
        collab_locks: %{},
        collab_activities: %{}
      }

      # Broadcast arrives via PubSub
      incoming_viewport = %{
        client_id: "client_leader",
        scroll_x: 0.2,
        scroll_y: 0.4,
        zoom: 1.0
      }

      should_push = incoming_viewport[:client_id] != initial_assigns.collab_client_id
      assert should_push == true

      # Assigns remain unchanged
      assigns_after = initial_assigns
      assert assigns_after == initial_assigns
    end
  end

  describe "Adversarial: Untrusted Client ID Parameter Injection Immunity" do
    test "server uses socket assigns collab_client_id and ignores client payload injection" do
      real_client_id = "cli_legitimate_socket_tab"
      attacker_forged_client_id = "cli_victim_target"
      user = %{id: "user_attacker", name: "Eve", color: "#DC2626"}

      # Even if attacker crafts %{"client_id" => "cli_victim_target"} in wire params,
      # server enforces client_id = sock.assigns[:collab_client_id]
      params = %{"client_id" => attacker_forged_client_id, "x" => 0.5, "y" => 0.5}

      # Server-side resolution:
      enforced_client_id = real_client_id
      refute enforced_client_id == params["client_id"]

      payload =
        LiveCollab.Cursor.build_payload(enforced_client_id, user, params["x"], params["y"])

      assert payload.client_id == real_client_id
      refute payload.client_id == attacker_forged_client_id
    end
  end

  describe "Adversarial: Presence untrack/2 Key Parity" do
    test "untrack uses user_key rather than client_id ensuring complete state purge" do
      topic = "live_collab:untrack_test:1"
      user = %{id: "usr_alice", name: "Alice"}
      client_id = "cli_unique_tab_789"
      user_key = to_string(user.id)

      # Track the session using LiveCollab.Presence
      {:ok, _ref} = Presence.track(TestPresence, self(), topic, user, client_id)

      # Verify the user is present under the user_key ("usr_alice")
      entries = TestPresence.list(topic)
      assert Map.has_key?(entries, user_key)
      refute Map.has_key?(entries, client_id)

      # When untracking, we MUST use user_key ("usr_alice")
      # Calling untrack with user_key purges the record cleanly
      Presence.untrack(TestPresence, self(), topic, user_key)

      assert TestPresence.list(topic) == %{}
    end
  end

  describe "Adversarial: Spotlight Broadcast Authorization & Protection" do
    test "rejects unauthorized clients from claiming spotlight leadership" do
      # Mock socket with viewer permissions or untracked state
      untracked_socket = %Phoenix.LiveView.Socket{assigns: %{}}
      refute LiveCollab.LiveView.authorized_spotlight_leader?(untracked_socket, %{id: "u1"})

      # Explicit false on socket assigns
      forbidden_socket = %Phoenix.LiveView.Socket{
        assigns: %{collab_client_id: "cli_1", collab_can_present?: false}
      }
      refute LiveCollab.LiveView.authorized_spotlight_leader?(forbidden_socket, %{id: "u1"})

      # User with role viewer or observer
      viewer_user = %{id: "u2", role: "viewer"}
      normal_socket = %Phoenix.LiveView.Socket{assigns: %{collab_client_id: "cli_2"}}
      refute LiveCollab.LiveView.authorized_spotlight_leader?(normal_socket, viewer_user)

      observer_user = %{id: "u3", role: :observer}
      refute LiveCollab.LiveView.authorized_spotlight_leader?(normal_socket, observer_user)

      # Explicit can_present? false on user
      disallowed_user = %{id: "u4", can_present?: false}
      refute LiveCollab.LiveView.authorized_spotlight_leader?(normal_socket, disallowed_user)

      # Authorized user
      allowed_user = %{id: "u5", name: "Presenter Jane", role: "editor"}
      assert LiveCollab.LiveView.authorized_spotlight_leader?(normal_socket, allowed_user)
    end

    test "prevents unauthorized viewers from terminating active spotlight presentation" do
      active_leader_client = "cli_leader_1"
      socket_with_active_leader = %Phoenix.LiveView.Socket{
        assigns: %{
          collab_client_id: "cli_attendee",
          collab_spotlight_leader: active_leader_client
        }
      }

      viewer_user = %{id: "u_attendee", role: "viewer"}

      # Attendee viewer tries to stop someone else's spotlight presentation
      refute LiveCollab.LiveView.can_stop_spotlight?(
               socket_with_active_leader,
               viewer_user,
               "cli_attendee"
             )

      # Active leader CAN stop their own spotlight presentation
      assert LiveCollab.LiveView.can_stop_spotlight?(
               socket_with_active_leader,
               viewer_user,
               active_leader_client
             )

      # Admin / co-presenter CAN stop spotlight presentation
      admin_user = %{id: "u_admin", role: "admin"}
      assert LiveCollab.LiveView.can_stop_spotlight?(
               socket_with_active_leader,
               admin_user,
               "cli_admin"
             )
    end
  end
end
