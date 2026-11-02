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
end
