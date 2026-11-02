defmodule LiveCollab.ComponentsTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Components

  describe "collab_attrs/4" do
    test "generates standard unlocked hook attributes" do
      locks = %{}
      attrs = Components.collab_attrs("customer.name", locks, "client_me")

      assert Keyword.get(attrs, :"phx-hook") == "LiveCollabField"
      assert Keyword.get(attrs, :"data-collab-field") == "customer.name"
      assert Keyword.get(attrs, :"data-collab-locked") == "false"
      assert Keyword.get(attrs, :"data-collab-locked-by-client") == ""
      refute Keyword.has_key?(attrs, :readonly)
      refute Keyword.has_key?(attrs, :"aria-readonly")
    end

    test "generates readonly attributes when locked by another client" do
      locks = %{
        "customer.name" => %{
          client_id: "client_other",
          user_name: "Bob",
          field: "customer.name"
        }
      }

      attrs = Components.collab_attrs("customer.name", locks, "client_me")

      assert Keyword.get(attrs, :"data-collab-locked") == "true"
      assert Keyword.get(attrs, :"data-collab-locked-by-client") == "client_other"
      assert Keyword.get(attrs, :readonly) == "readonly"
      assert Keyword.get(attrs, :"aria-readonly") == "true"
    end

    test "does not mark readonly if held by the current client" do
      locks = %{
        "customer.name" => %{
          client_id: "client_me",
          user_name: "Me",
          field: "customer.name"
        }
      }

      attrs = Components.collab_attrs("customer.name", locks, "client_me")

      assert Keyword.get(attrs, :"data-collab-locked") == "false"
      refute Keyword.has_key?(attrs, :readonly)
    end

    test "respects readonly: false option override" do
      locks = %{
        "customer.name" => %{
          client_id: "client_other",
          user_name: "Bob",
          field: "customer.name"
        }
      }

      attrs = Components.collab_attrs("customer.name", locks, "client_me", readonly: false)

      assert Keyword.get(attrs, :"data-collab-locked") == "true"
      refute Keyword.has_key?(attrs, :readonly)
    end
  end

  describe "collab_row_attrs/4" do
    test "generates default element hook attributes when inactive" do
      activities = %{}
      attrs = Components.collab_row_attrs("row:10", activities, "client_me")

      assert Keyword.get(attrs, :"phx-hook") == "LiveCollabElement"
      assert Keyword.get(attrs, :"data-collab-element") == "row:10"
      assert Keyword.get(attrs, :"data-collab-type") == "viewing"
      assert Keyword.get(attrs, :"data-collab-active") == "false"
      refute Keyword.has_key?(attrs, :style)
    end

    test "includes hover_intent when configured" do
      activities = %{}
      attrs = Components.collab_row_attrs("row:10", activities, "client_me", hover_intent: 300)

      assert Keyword.get(attrs, :"data-collab-hover-intent") == "300"
    end

    test "generates active styles and aria descriptions when active by another collaborator" do
      activities = %{
        "row:10" => [
          %{
            client_id: "client_other",
            user_name: "Sarah",
            user_color: "#DC2626",
            type: :viewing,
            acquired_at: 100
          }
        ]
      }

      attrs = Components.collab_row_attrs("row:10", activities, "client_me")

      assert Keyword.get(attrs, :"data-collab-active") == "true"
      assert Keyword.get(attrs, :style) == "--collab-element-color: #DC2626;"
      assert Keyword.get(attrs, :"aria-description") == "Sarah is viewing on this item"
    end
  end

  describe "collab_cursor_attrs/2" do
    test "generates default cursor hook attributes" do
      attrs = Components.collab_cursor_attrs("canvas_main")

      assert Keyword.get(attrs, :"phx-hook") == "LiveCollabCursor"
      assert Keyword.get(attrs, :"data-collab-container") == "canvas_main"
      assert Keyword.get(attrs, :"data-collab-throttle") == "30"
      assert Keyword.get(attrs, :"data-collab-deadband") == "0.0015"
    end

    test "respects custom throttle and deadband options" do
      attrs = Components.collab_cursor_attrs("board", throttle: 50, deadband: 0.005)

      assert Keyword.get(attrs, :"data-collab-throttle") == "50"
      assert Keyword.get(attrs, :"data-collab-deadband") == "0.005"
    end
  end

  describe "collab_viewport_attrs/2" do
    test "generates default viewport hook attributes" do
      attrs = Components.collab_viewport_attrs("doc_view")

      assert Keyword.get(attrs, :"phx-hook") == "LiveCollabViewport"
      assert Keyword.get(attrs, :"data-collab-container") == "doc_view"
      assert Keyword.get(attrs, :"data-collab-presenter") == "false"
      assert Keyword.get(attrs, :"data-collab-throttle") == "40"
      refute Keyword.has_key?(attrs, :"data-collab-following")
    end

    test "includes presenter and following attributes when provided" do
      attrs =
        Components.collab_viewport_attrs("doc_view",
          presenter: true,
          following: "leader_client_1",
          throttle: 60
        )

      assert Keyword.get(attrs, :"data-collab-presenter") == "true"
      assert Keyword.get(attrs, :"data-collab-following") == "leader_client_1"
      assert Keyword.get(attrs, :"data-collab-throttle") == "60"
    end
  end

  describe "collab_selection_attrs/2" do
    test "generates selection hook attributes" do
      attrs = Components.collab_selection_attrs("artboard_1")

      assert Keyword.get(attrs, :"phx-hook") == "LiveCollabSelection"
      assert Keyword.get(attrs, :"data-collab-container") == "artboard_1"
    end
  end
end
