defmodule LiveCollab.AdversarialTest do
  @moduledoc """
  Adversarial test suite designed to challenge and break assumptions:
  - Race conditions and lock contention
  - Process crashes and stale lock recovery
  - Malformed and malicious client payloads
  - Multi-tab self contention and cross-tab isolation
  - Network partition healing simulation
  - Shared multi-user element and row activity concurrency

  Presence-backed tests run against a real Phoenix.Presence (see
  test/support/integration.ex), each on its own topic. End-to-end behaviour
  through LiveView processes lives in test/integration/.
  """

  use ExUnit.Case, async: false
  alias LiveCollab.Element
  alias LiveCollab.Field
  alias LiveCollab.Presence
  alias LiveCollab.Test.Presence, as: TestPresence

  defp topic, do: "live_collab:adversarial:#{System.unique_integer([:positive])}"

  defp idle_process do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(pid, :stop) end)
    pid
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
      topic = topic()
      tab_pid = idle_process()

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

      # Simulate sudden tab close / process crash. Phoenix.Tracker monitors the
      # tracked pid and removes its presences when the :DOWN arrives.
      Process.exit(tab_pid, :kill)
      wait_until(fn -> TestPresence.list(topic) == %{} end)

      # Verify both are purged automatically
      refute Map.has_key?(Field.extract_locks(TestPresence.list(topic)), "billing.credit_card")
      refute Map.has_key?(Element.extract_activities(TestPresence.list(topic)), "row:42")
    end
  end

  describe "Adversarial: Multi-Tab Self-Contention" do
    test "same user with multiple tabs has isolated tab locks" do
      topic = topic()
      user = %{id: "user_multi", name: "Power User"}

      # Tab 1
      tab1_pid = idle_process()
      client_1 = "tab_uuid_1"
      {:ok, _} = TestPresence.track(tab1_pid, topic, user.id, %{client_id: client_1})

      # Tab 2
      tab2_pid = idle_process()
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
    end
  end

  describe "Adversarial: Multi-User Element Concurrency (Shared Presence)" do
    test "multiple distinct users on the same row coexist peacefully without collision" do
      topic = topic()

      # 4 users viewing or editing the same row
      for i <- 1..4 do
        pid = idle_process()
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
  end

  describe "Adversarial: High-Frequency Cursor Telemetry (Path 2 Protection)" do
    test "rejects coordinate attacks (NaN, infinity, extreme coordinates)" do
      assert {:error, :coordinate_out_of_bounds} =
               LiveCollab.Cursor.validate_coordinates(999_999_999.0, 0.5)

      assert {:error, :coordinate_out_of_bounds} =
               LiveCollab.Cursor.validate_coordinates(-100.0, 0.5)

      assert {:error, :invalid_coordinate_format} =
               LiveCollab.Cursor.validate_coordinates("<script>0.5</script>", 0.5)
    end
  end

  describe "Adversarial: Viewport Following & Selection Telemetry (Path 2 Protection)" do
    test "rejects malicious viewport and selection attacks" do
      assert {:error, :scroll_out_of_bounds} =
               LiveCollab.Viewport.validate_viewport(99_999.0, 0.5)

      assert {:error, :scroll_out_of_bounds} =
               LiveCollab.Viewport.validate_viewport(-50.0, 0.5)

      assert {:error, :zoom_out_of_bounds} =
               LiveCollab.Viewport.validate_viewport(0.5, 0.5, 999.0)

      assert {:error, :negative_dimensions} =
               LiveCollab.Viewport.validate_selection(0.1, 0.2, -100.0, 50.0)

      assert {:error, :selection_out_of_bounds} =
               LiveCollab.Viewport.validate_selection(500.0, 0.0, 10.0, 10.0)
    end
  end

  describe "Adversarial: Untrusted Client ID Parameter Injection Immunity" do
  end

  describe "Adversarial: Presence untrack/2 Key Parity" do
    test "untrack uses user_key rather than client_id ensuring complete state purge" do
      topic = topic()
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

  describe "Adversarial: Telemetry Flood Rate Limiting (Token Bucket Defense)" do
    test "drops flood events when malicious client exceeds telemetry rate limits" do
      # Limiter configured with burst of 10 and steady-state 50/sec
      limiter = LiveCollab.RateLimiter.new(rate: 50, burst: 10, now_ms: 1000)

      # Simulate an adversarial client flooding 50 cursor events in 1 millisecond
      results =
        Enum.reduce(1..50, {[], limiter}, fn _i, {acc, cur_limiter} ->
          case LiveCollab.RateLimiter.check(cur_limiter, 1, 1000) do
            {:allow, next_limiter} -> {[:allowed | acc], next_limiter}
            {:deny, next_limiter} -> {[:denied | acc], next_limiter}
          end
        end)

      {outcomes, final_limiter} = results

      allowed_count = Enum.count(outcomes, &(&1 == :allowed))
      denied_count = Enum.count(outcomes, &(&1 == :denied))

      # Only 10 burst events are permitted; the remaining 40 flood events are dropped
      assert allowed_count == 10
      assert denied_count == 40
      assert_in_delta final_limiter.tokens, 0.0, 0.001
    end
  end

  describe "Adversarial: Multi-Node Cluster Clock Skew & Seniority Hardening" do
    test "3-node cluster with 150ms clock skew converges to identical winner" do
      base_time = 1_700_000_000_000

      # Contenders concurrently claiming the same field across 3 nodes with drifted clocks
      # all falling within the same 500ms tolerance bucket:
      node1_claim = %{
        client_id: "client_b",
        user_id: "u_bob",
        acquired_at: base_time + 20,
        field: "balance"
      }

      node2_claim = %{
        client_id: "client_c",
        user_id: "u_charlie",
        acquired_at: base_time + 100,
        field: "balance"
      }

      node3_claim = %{
        client_id: "client_a",
        user_id: "u_alice",
        acquired_at: base_time + 180,
        field: "balance"
      }

      claims = [node1_claim, node2_claim, node3_claim]

      # Shuffled to simulate gossip message arrival orders on different nodes
      perm1 = Enum.shuffle(claims)
      perm2 = Enum.shuffle(claims)
      perm3 = Enum.shuffle(claims)

      # With 500ms tolerance, all fall into the same concurrency window
      # The winner MUST be chosen deterministically by client_id ("client_a")
      winner1 = Field.resolve_conflict(perm1, 500)
      winner2 = Field.resolve_conflict(perm2, 500)
      winner3 = Field.resolve_conflict(perm3, 500)

      assert winner1.client_id == "client_a"
      assert winner2.client_id == "client_a"
      assert winner3.client_id == "client_a"
    end

    test "re-focusing the same field preserves lock acquisition seniority timestamp" do
      topic = topic()
      user = %{id: "u1", name: "Alice"}
      client_id = "cli_senior_1"

      {:ok, _} = Presence.track(TestPresence, self(), topic, user, client_id)

      # Focus field first time
      Presence.update_field(TestPresence, self(), topic, user.id, "email", client_id)
      entries1 = TestPresence.list(topic)
      initial_meta = hd(entries1[to_string(user.id)].metas)
      initial_acquired_at = initial_meta.acquired_at
      assert is_integer(initial_acquired_at) and initial_acquired_at > 0

      # Simulate re-render or re-focus on the same field
      Presence.update_field(TestPresence, self(), topic, user.id, "email", client_id)
      entries2 = TestPresence.list(topic)
      updated_meta = hd(entries2[to_string(user.id)].metas)

      # Acquired timestamp must be strictly preserved!
      assert updated_meta.acquired_at == initial_acquired_at
    end

    test "handle_presence_sync resets local editing field if lock dropped in Presence" do
      # Socket believed it was editing "notes"
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          collab_client_id: "cli_local",
          collab_editing_field: "notes",
          collab_users: [],
          collab_locks: %{},
          collab_activities: %{},
          collab_config: %LiveCollab.Config{}
        },
        private: %{live_temp: %{}}
      }

      # Presence topic has no locks
      synced_socket =
        LiveCollab.LiveView.handle_presence_sync(socket, TestPresence, "empty_topic")

      # Local editing field was safely reset to nil
      assert synced_socket.assigns.collab_editing_field == nil
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(5) && wait_until(fun, attempts - 1)
    end
  end
end
