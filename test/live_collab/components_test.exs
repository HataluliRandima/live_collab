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

  describe "follow_pill/1" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "uses JS.dispatch instead of inline JavaScript (CSP-safe, no injection)" do
      html =
        render_component(&Components.follow_pill/1,
          leader_name: "Ann",
          leader_client_id: "cli_x');alert(1);//",
          leader_color: "#123456"
        )

      refute html =~ "onclick"
      assert html =~ "phx-click"
      assert html =~ "live_collab:start_follow"
    end
  end

  describe "color sanitization in rendered markup" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "avatar colors cannot inject CSS" do
      user = %{
        id: "u",
        name: "Ann",
        avatar_url: nil,
        initials: "AN",
        tabs_count: 1,
        color: "red; background-image: url(https://evil.example)"
      }

      html = render_component(&Components.avatar/1, user: user)

      refute html =~ "evil.example"
      assert html =~ ~r/background-color: #[0-9A-F]{6};/
    end

    test "collab_row_attrs/4 sanitizes the CSS variable color" do
      activities = %{
        "row:1" => [%{client_id: "x", user_name: "Ann", user_color: "x;}*{}", type: :viewing}]
      }

      style = Components.collab_row_attrs("row:1", activities, "me") |> Keyword.get(:style)
      assert style =~ ~r/\A--collab-element-color: #[0-9A-F]{6};\z/
    end
  end

  describe "hook ids (LiveView requires a DOM id on phx-hook elements)" do
    test "every helper emits a deterministic, selector-safe id" do
      assert Keyword.get(Components.collab_attrs("order.name", %{}, "me"), :id) ==
               "live-collab-field-order_2ename"

      assert Keyword.get(Components.collab_row_attrs("row:42", %{}, "me"), :id) ==
               "live-collab-element-row_3a42"

      assert Keyword.get(Components.collab_cursor_attrs("canvas"), :id) ==
               "live-collab-cursor-canvas"

      assert Keyword.get(Components.collab_viewport_attrs("doc"), :id) ==
               "live-collab-viewport-doc"

      assert Keyword.get(Components.collab_selection_attrs("b"), :id) == "live-collab-selection-b"
    end

    test "distinct identifiers never collide" do
      ids =
        for f <- ["a.b", "a:b", "a_b", "a-b", "a b"],
            do: Keyword.get(Components.collab_attrs(f, %{}, nil), :id)

      assert length(Enum.uniq(ids)) == 5
      assert Enum.all?(ids, &Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, &1))
    end

    test "id can be overridden or omitted" do
      assert Keyword.get(Components.collab_attrs("f", %{}, nil, id: "mine"), :id) == "mine"
      refute Keyword.has_key?(Components.collab_attrs("f", %{}, nil, id: false), :id)
    end
  end

  describe "away status rendering" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "away users are dimmed and labelled" do
      user = %{
        id: "u",
        name: "Ann",
        avatar_url: nil,
        initials: "AN",
        tabs_count: 1,
        color: "#123456"
      }

      away = render_component(&Components.avatar/1, user: Map.put(user, :status, :away))
      active = render_component(&Components.avatar/1, user: Map.put(user, :status, :active))

      assert away =~ "live-collab-away"
      assert away =~ ~s|aria-label="Collaborator Ann (away)"|
      refute active =~ "live-collab-away"
    end

    test "status_reporter renders a hook element with an id" do
      html = render_component(&Components.status_reporter/1, idle_after: 5_000)
      assert html =~ ~s(phx-hook="LiveCollabStatus")
      assert html =~ ~s(id="live-collab-status")
      assert html =~ ~s(data-collab-idle-after="5000")
    end
  end

  describe "overlays" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "cursor and selection layers render an ignored overlay LiveView will not discard" do
      for {fun, prefix} <- [
            {&Components.cursor_layer/1, "live-collab-cursor-board"},
            {&Components.selection_layer/1, "live-collab-selection-board"}
          ] do
        html = render_component(fun, container_id: "board", inner_block: [])

        overlay =
          html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-collab-layer]")

        assert LazyHTML.attribute(overlay, "id") == ["#{prefix}-layer"]
        assert LazyHTML.attribute(overlay, "phx-update") == ["ignore"]
      end
    end
  end

  describe "lock handoff and change notice components" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    @lock %{
      "title" => %{
        client_id: "cli_alice",
        user_id: "alice",
        user_name: "Alice",
        user_color: "#DC2626"
      }
    }

    test "field_indicator offers Ask to edit only when asks are given" do
      without =
        render_component(&Components.field_indicator/1,
          field: "title",
          locks: @lock,
          current_client_id: "me"
        )

      refute without =~ "Ask to edit"

      ask =
        render_component(&Components.field_indicator/1,
          field: "title",
          locks: @lock,
          current_client_id: "me",
          asks: %{}
        )

      assert ask =~ "Ask to edit"
      assert ask =~ ~s(phx-click="live_collab:lock_request")
      assert ask =~ ~s(phx-value-field="title")

      pending =
        render_component(&Components.field_indicator/1,
          field: "title",
          locks: @lock,
          current_client_id: "me",
          asks: %{"title" => :pending}
        )

      assert pending =~ "Request sent"
      refute pending =~ "Ask to edit"

      declined =
        render_component(&Components.field_indicator/1,
          field: "title",
          locks: @lock,
          current_client_id: "me",
          asks: %{"title" => :declined}
        )

      assert declined =~ "Declined"
    end

    test "lock_requests renders hand over / keep editing for each request" do
      requests = %{"title" => [%{client_id: "cli_bob", user_name: "Bob", user_color: "#2563EB"}]}
      html = render_component(&Components.lock_requests/1, requests: requests)

      assert html =~ "Bob wants to edit"
      assert html =~ ~s(phx-value-to="cli_bob")
      assert html =~ ~s(phx-value-accept="true")
      assert html =~ ~s(phx-value-accept="false")

      assert render_component(&Components.lock_requests/1, requests: requests, field: "other") =~
               ~r/\A\s*\z/
    end

    test "field_change_notice targets the input id generated by collab_attrs/4" do
      changes = %{
        "order.name" => %{
          value: "Acme",
          by_name: "Alice",
          by_color: "#DC2626",
          by_client_id: "cli_a",
          at: 1
        }
      }

      html =
        render_component(&Components.field_change_notice/1, field: "order.name", changes: changes)

      assert html =~ "Alice saved “Acme” while you were editing."
      assert html =~ Components.field_dom_id("order.name")
      assert html =~ "live_collab:apply_remote"
      assert html =~ "live_collab:dismiss_change"

      assert Keyword.get(Components.collab_attrs("order.name", %{}, nil), :id) ==
               Components.field_dom_id("order.name")

      assert render_component(&Components.field_change_notice/1, field: "x", changes: changes) =~
               ~r/\A\s*\z/
    end
  end
end
