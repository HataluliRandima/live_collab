defmodule LiveCollab.ViewportTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Viewport

  describe "validate_viewport/3" do
    test "accepts valid normalized scroll percentages and zoom" do
      assert {:ok, 0.5, 0.8, 1.0} = Viewport.validate_viewport(0.5, 0.8)
      assert {:ok, 0.0, 1.0, 1.5} = Viewport.validate_viewport(0, 1, 1.5)
      assert {:ok, 0.25, 0.75, 2.0} = Viewport.validate_viewport("0.25", "0.75", "2.0")
    end

    test "accepts slight negative/overshoot margin for bounce-scroll" do
      assert {:ok, -0.05, 1.05, 1.0} = Viewport.validate_viewport(-0.05, 1.05, 1.0)
    end

    test "rejects out of bounds scroll percentages" do
      assert {:error, :scroll_out_of_bounds} = Viewport.validate_viewport(-0.5, 0.5)
      assert {:error, :scroll_out_of_bounds} = Viewport.validate_viewport(0.5, 2.0)
    end

    test "rejects out of bounds zoom levels" do
      assert {:error, :zoom_out_of_bounds} = Viewport.validate_viewport(0.5, 0.5, 0.05)
      assert {:error, :zoom_out_of_bounds} = Viewport.validate_viewport(0.5, 0.5, 15.0)
    end

    test "rejects non-numeric data types" do
      assert {:error, :invalid_coordinate_type} = Viewport.validate_viewport(nil, 0.5)
      assert {:error, :invalid_coordinate_type} = Viewport.validate_viewport(0.5, %{})
      assert {:error, :invalid_coordinate_format} = Viewport.validate_viewport("bad", 0.5)
    end
  end

  describe "validate_selection/4" do
    test "accepts valid bounding boxes" do
      assert {:ok, 0.1, 0.2, 0.5, 0.4} = Viewport.validate_selection(0.1, 0.2, 0.5, 0.4)
      assert {:ok, 0.0, 0.0, 1.0, 1.0} = Viewport.validate_selection(0, 0, 1, 1)
      assert {:ok, 0.2, 0.3, 0.4, 0.5} = Viewport.validate_selection("0.2", "0.3", "0.4", "0.5")
    end

    test "rejects negative dimensions" do
      assert {:error, :negative_dimensions} = Viewport.validate_selection(0.1, 0.2, -0.5, 0.4)
      assert {:error, :negative_dimensions} = Viewport.validate_selection(0.1, 0.2, 0.5, -0.1)
    end

    test "rejects out of bounds coordinates" do
      assert {:error, :selection_out_of_bounds} = Viewport.validate_selection(-1.5, 0.2, 0.5, 0.4)
      assert {:error, :selection_out_of_bounds} = Viewport.validate_selection(0.2, 2.5, 0.5, 0.4)
    end
  end

  describe "build_viewport_payload/5" do
    test "constructs clean telemetry payload" do
      user = %{id: "user_presenter", name: "Dr. Elena", color: "#4F46E5"}
      client_id = "client_lead_1"

      payload =
        Viewport.build_viewport_payload(client_id, user, 0.333333, 0.666666,
          zoom: 1.25,
          container_id: "doc_view",
          anchor_element_id: "heading_3"
        )

      assert payload.client_id == "client_lead_1"
      assert payload.user_id == "user_presenter"
      assert payload.user_name == "Dr. Elena"
      assert payload.user_color == "#4F46E5"
      assert payload.scroll_x == 0.3333
      assert payload.scroll_y == 0.6667
      assert payload.zoom == 1.25
      assert payload.container_id == "doc_view"
      assert payload.anchor_element_id == "heading_3"
      assert is_integer(payload.timestamp)
    end
  end

  describe "build_selection_payload/7" do
    test "constructs clean selection payload with selected items" do
      user = %{id: "user_designer", name: "Marcus", color: "#059669"}
      client_id = "client_marcus"

      payload =
        Viewport.build_selection_payload(client_id, user, 0.1, 0.15, 0.4, 0.3,
          container_id: "artboard_1",
          selected_ids: ["card_1", "card_2"]
        )

      assert payload.client_id == "client_marcus"
      assert payload.user_name == "Marcus"
      assert payload.x == 0.1
      assert payload.y == 0.15
      assert payload.width == 0.4
      assert payload.height == 0.3
      assert payload.selected_ids == ["card_1", "card_2"]
    end
  end
end

