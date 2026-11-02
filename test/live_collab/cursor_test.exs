defmodule LiveCollab.CursorTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Cursor

  describe "validate_coordinates/2" do
    test "accepts valid normalized float coordinates" do
      assert {:ok, 0.45, 0.88} = Cursor.validate_coordinates(0.45, 0.88)
      assert {:ok, 0.0, 1.0} = Cursor.validate_coordinates(0.0, 1.0)
    end

    test "accepts integers and converts to float" do
      assert {:ok, 0.0, 1.0} = Cursor.validate_coordinates(0, 1)
    end

    test "accepts valid string-encoded numbers" do
      assert {:ok, 0.25, 0.75} = Cursor.validate_coordinates("0.25", "0.75")
    end

    test "accepts coordinates with slight margin for edge tracking" do
      assert {:ok, -0.15, 1.15} = Cursor.validate_coordinates(-0.15, 1.15)
    end

    test "rejects out of bounds coordinates" do
      assert {:error, :coordinate_out_of_bounds} = Cursor.validate_coordinates(-0.5, 0.5)
      assert {:error, :coordinate_out_of_bounds} = Cursor.validate_coordinates(0.5, 2.5)
      assert {:error, :coordinate_out_of_bounds} = Cursor.validate_coordinates(99999.0, 0.0)
    end

    test "rejects non-numeric data types" do
      assert {:error, :invalid_coordinate_type} = Cursor.validate_coordinates(nil, 0.5)
      assert {:error, :invalid_coordinate_type} = Cursor.validate_coordinates(%{"x" => 1}, 0.5)
      assert {:error, :invalid_coordinate_type} = Cursor.validate_coordinates([1, 2], 0.5)
      assert {:error, :invalid_coordinate_format} = Cursor.validate_coordinates("not_a_number", 0.5)
    end
  end

  describe "build_payload/5" do
    test "constructs clean telemetry payload with rounded coordinates and user metadata" do
      user = %{id: "user_77", name: "Vincent", color: "#DB2777"}
      client_id = "client_tab_1"

      payload = Cursor.build_payload(client_id, user, 0.1234567, 0.7654321, "canvas_board")

      assert payload.client_id == "client_tab_1"
      assert payload.user_id == "user_77"
      assert payload.user_name == "Vincent"
      assert payload.user_color == "#DB2777"
      assert payload.container_id == "canvas_board"
      assert payload.x == 0.1235
      assert payload.y == 0.7654
      assert is_integer(payload.timestamp)
    end

    test "falls back to deterministic color if user color is missing" do
      user = %{id: "user_99", name: "Anonymous"}
      payload = Cursor.build_payload("c1", user, 0.5, 0.5)

      assert is_binary(payload.user_color)
      assert String.starts_with?(payload.user_color, "#")
    end
  end
end

