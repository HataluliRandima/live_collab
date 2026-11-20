defmodule LiveCollab.PresenceTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Presence

  describe "initials/1" do
    test "extracts initials from single names" do
      assert Presence.initials("Alice") == "AL"
      assert Presence.initials("Bob") == "BO"
      assert Presence.initials("X") == "X"
    end

    test "extracts initials from two-part names" do
      assert Presence.initials("John Doe") == "JD"
      assert Presence.initials("Jane Smith") == "JS"
    end

    test "extracts first and last initials for multi-word names" do
      assert Presence.initials("Martin Luther King") == "MK"
      assert Presence.initials("Alex van der Linden") == "AL"
    end

    test "handles leading, trailing, and duplicate spaces" do
      assert Presence.initials("  Ada   Lovelace  ") == "AL"
    end

    test "returns fallback for empty or nil names" do
      assert Presence.initials("") == "?"
      assert Presence.initials(nil) == "?"
      assert Presence.initials("   ") == "?"
    end
  end

  describe "deterministic_color/1" do
    test "returns the same color hex code for the same identifier" do
      color1 = Presence.deterministic_color("user_123")
      color2 = Presence.deterministic_color("user_123")
      assert color1 == color2
      assert String.starts_with?(color1, "#")
    end

    test "handles integer and atom identifiers" do
      color_int = Presence.deterministic_color(42)
      color_atom = Presence.deterministic_color(:admin)
      assert is_binary(color_int)
      assert is_binary(color_atom)
    end
  end

  describe "extract_users/1" do
    test "consolidates multiple tabs for the same user" do
      presence_entries = %{
        "user_1" => %{
          metas: [
            %{
              client_id: "tab_1",
              user_id: "user_1",
              user_name: "Sarah Connor",
              field: "target"
            },
            %{
              client_id: "tab_2",
              user_id: "user_1",
              user_name: "Sarah Connor",
              field: nil
            }
          ]
        },
        "user_2" => %{
          metas: [
            %{
              client_id: "tab_3",
              user_id: "user_2",
              user_name: "Kyle Reese",
              field: "status"
            }
          ]
        }
      }

      users = Presence.extract_users(presence_entries)
      assert length(users) == 2

      sarah = Enum.find(users, &(&1.id == "user_1"))
      assert sarah.name == "Sarah Connor"
      assert sarah.tabs_count == 2
      assert sarah.initials == "SC"
      assert sarah.active_fields == ["target"]

      kyle = Enum.find(users, &(&1.id == "user_2"))
      assert kyle.tabs_count == 1
      assert kyle.active_fields == ["status"]
    end
  end

  describe "identity/2" do
    test "accepts atom or string keys and falls back sensibly" do
      assert %{id: 1, key: "1", name: "Ann"} =
               Presence.identity(%{"id" => 1, "name" => "Ann"}, "c")

      assert %{id: "c", key: "c", name: "Guest"} = Presence.identity(%{}, "c")
    end

    test "replaces unsafe colors and drops unsafe avatar URLs" do
      identity =
        Presence.identity(
          %{id: "u", color: "red;background:url(x)", avatar_url: "javascript:alert(1)"},
          "c"
        )

      assert identity.color == Presence.deterministic_color("u")
      assert identity.avatar_url == nil
    end
  end

  describe "track/6 with a real Phoenix.Presence" do
    test "regression: accepts a LiveView socket by tracking the calling process" do
      # Phoenix.Tracker.track/5 only accepts pids; passing the socket used to
      # raise FunctionClauseError on every connected mount.
      topic = "live_collab:presence_test:#{System.unique_integer([:positive])}"
      socket = %Phoenix.LiveView.Socket{}

      assert {:ok, _ref} =
               Presence.track(LiveCollab.Test.Presence, socket, topic, %{id: "u1"}, "cli_1")

      assert [{pid, %{client_id: "cli_1"}}] =
               Phoenix.Tracker.get_by_key(LiveCollab.Test.Presence, topic, "u1")

      assert pid == self()
    end
  end
end
