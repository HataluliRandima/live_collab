defmodule LiveCollab.ElementTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Element

  describe "validate_element_id/2" do
    test "accepts valid element identifiers" do
      assert {:ok, "row:42"} = Element.validate_element_id("row:42")
      assert {:ok, "card:task_123"} = Element.validate_element_id("card:task_123")
      assert {:ok, "section-billing"} = Element.validate_element_id("section-billing")
      assert {:ok, "table[0][1]"} = Element.validate_element_id("table[0][1]")
      assert {:ok, "user/profile/header"} = Element.validate_element_id("user/profile/header")
    end

    test "rejects empty or whitespace element id" do
      assert {:error, :empty_element_id} = Element.validate_element_id("")
    end

    test "rejects malicious or disallowed characters" do
      assert {:error, :disallowed_characters} =
               Element.validate_element_id("<script>alert(1)</script>")

      assert {:error, :disallowed_characters} =
               Element.validate_element_id("row 42 with spaces")

      assert {:error, :disallowed_characters} =
               Element.validate_element_id("row; DROP TABLE users")
    end

    test "rejects oversized strings" do
      oversized = String.duplicate("x", 256)
      assert {:error, :element_id_too_long} = Element.validate_element_id(oversized, 255)
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_type} = Element.validate_element_id(42)
      assert {:error, :invalid_type} = Element.validate_element_id(nil)
    end
  end

  describe "normalize_activity_type/1" do
    test "normalizes supported atom and string types" do
      assert Element.normalize_activity_type(:viewing) == :viewing
      assert Element.normalize_activity_type("viewing") == :viewing
      assert Element.normalize_activity_type(:selected) == :selected
      assert Element.normalize_activity_type("selected") == :selected
      assert Element.normalize_activity_type(:editing) == :editing
      assert Element.normalize_activity_type("editing") == :editing
    end

    test "falls back to :viewing for unknown types" do
      assert Element.normalize_activity_type(:unknown) == :viewing
      assert Element.normalize_activity_type(nil) == :viewing
      assert Element.normalize_activity_type("random") == :viewing
    end
  end

  describe "extract_activities/2" do
    test "extracts multiple collaborators on the same element" do
      presence_entries = %{
        "user_1" => %{
          metas: [
            %{
              client_id: "c1",
              user_id: "user_1",
              user_name: "Alice",
              element: "row:101",
              element_type: :viewing,
              element_acquired_at: 100,
              field: nil
            }
          ]
        },
        "user_2" => %{
          metas: [
            %{
              client_id: "c2",
              user_id: "user_2",
              user_name: "Bob",
              element: "row:101",
              element_type: :selected,
              element_acquired_at: 150,
              field: nil
            }
          ]
        }
      }

      activities = Element.extract_activities(presence_entries)
      assert Map.has_key?(activities, "row:101")

      users = activities["row:101"]
      assert length(users) == 2

      alice = Enum.find(users, &(&1.user_id == "user_1"))
      assert alice.user_name == "Alice"
      assert alice.type == :viewing

      bob = Enum.find(users, &(&1.user_id == "user_2"))
      assert bob.user_name == "Bob"
      assert bob.type == :selected
    end

    test "upgrades user activity to :editing if they have an active field inside the element" do
      presence_entries = %{
        "user_1" => %{
          metas: [
            %{
              client_id: "c1",
              user_id: "user_1",
              user_name: "Charlie",
              element: "row:200",
              element_type: :viewing,
              element_acquired_at: 200,
              field: "task.title"
            }
          ]
        }
      }

      activities = Element.extract_activities(presence_entries)
      [charlie] = activities["row:200"]
      assert charlie.type == :editing
      assert charlie.field == "task.title"
    end

    test "consolidates multi-tab sessions for the same user with highest precedence activity" do
      presence_entries = %{
        "user_1" => %{
          metas: [
            %{
              client_id: "c1",
              user_id: "user_1",
              user_name: "Alice",
              element: "row:300",
              element_type: :viewing,
              element_acquired_at: 100,
              field: nil
            },
            %{
              client_id: "c2",
              user_id: "user_1",
              user_name: "Alice",
              element: "row:300",
              element_type: :editing,
              element_acquired_at: 120,
              field: "row.amount"
            }
          ]
        }
      }

      activities = Element.extract_activities(presence_entries, dedup_users: true)
      users = activities["row:300"]
      # Alice consolidated into 1 entry with :editing
      assert length(users) == 1
      assert hd(users).type == :editing
    end
  end

  describe "activity helper queries" do
    setup do
      activities = %{
        "row:1" => [
          %{
            client_id: "c1",
            user_id: "u1",
            user_name: "Alice",
            user_color: "#4F46E5",
            type: :editing,
            field: "row1.col1",
            acquired_at: 10
          },
          %{
            client_id: "c2",
            user_id: "u2",
            user_name: "Bob",
            user_color: "#059669",
            type: :viewing,
            field: nil,
            acquired_at: 20
          }
        ]
      }

      {:ok, activities: activities}
    end

    test "active_users/2 returns list of users on element", %{activities: activities} do
      assert length(Element.active_users(activities, "row:1")) == 2
      assert Element.active_users(activities, "row:99") == []
    end

    test "active_by_other?/3 checks if other clients are active", %{activities: activities} do
      # For client c1, client c2 is also active on row:1
      assert Element.active_by_other?(activities, "row:1", "c1")
      # For an outside client c3, others are active
      assert Element.active_by_other?(activities, "row:1", "c3")
      # For an empty row, false
      refute Element.active_by_other?(activities, "row:99", "c1")
    end

    test "editing?/2 checks if any user is currently editing the row", %{activities: activities} do
      assert Element.editing?(activities, "row:1")
      refute Element.editing?(activities, "row:99")
    end
  end
end

