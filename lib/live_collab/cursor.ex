defmodule LiveCollab.Cursor do
  @moduledoc """
  High-frequency ephemeral cursor telemetry manager.

  Coordinates and telemetry payloads bypass `Phoenix.Presence` and LiveView's
  assigns/diff engine completely:
  - Broadcast directly across `Phoenix.PubSub`
  - Relayed to clients via `Phoenix.LiveView.push_event/3`
  - Zero LiveView template re-renders or DOM diff computations
  - Rendered client-side via hardware-accelerated SVG and `requestAnimationFrame`.

  ## Coordinate Normalization

  To support responsive layouts, multi-monitor setups, and different viewport sizes,
  cursor positions are transmitted as **normalized coordinates** relative to a target container:

      x = (cursor_client_x - container_left) / container_width
      y = (cursor_client_y - container_top) / container_height

  Both `x` and `y` are floats in the nominal range `[0.0, 1.0]`. When rendered on
  collaborators' browsers, these normalized coordinates are multiplied by the local
  container dimensions, ensuring precise visual alignment regardless of display geometry.
  """

  @type normalized_coord :: float()

  @type cursor_payload :: %{
          required(:client_id) => String.t(),
          required(:user_id) => String.t() | integer(),
          required(:user_name) => String.t(),
          required(:user_color) => String.t(),
          required(:x) => normalized_coord(),
          required(:y) => normalized_coord(),
          optional(:container_id) => String.t() | nil,
          required(:timestamp) => integer()
        }

  @doc """
  Validates incoming cursor coordinates sent from a client.

  Ensures coordinates are:
  - Valid finite floating point or integer numbers
  - Not `NaN` or `Infinity`
  - Within allowable bounds (`-0.2 <= val <= 1.2` allowing for edge-drag overshoots)
  """
  @spec validate_coordinates(term(), term()) :: {:ok, float(), float()} | {:error, atom()}
  def validate_coordinates(x, y) do
    with {:ok, nx} <- coordinate(x),
         {:ok, ny} <- coordinate(y),
         :ok <- validate_bounds(nx, ny) do
      {:ok, nx, ny}
    end
  end

  @doc """
  Sanitizes and prepares a broadcast cursor payload.
  """
  @spec build_payload(
          client_id :: String.t(),
          user :: map(),
          x :: float(),
          y :: float(),
          container_id :: String.t() | nil
        ) :: cursor_payload()
  def build_payload(client_id, user, x, y, container_id \\ nil) do
    {user_id, user_name, user_color} = LiveCollab.Presence.display_fields(user, client_id)

    %{
      client_id: client_id,
      user_id: user_id,
      user_name: user_name,
      user_color: user_color,
      x: Float.round(x, 4),
      y: Float.round(y, 4),
      container_id: container_id,
      timestamp: System.system_time(:millisecond)
    }
  end

  # Error atoms are part of the public contract (:invalid_coordinate_format,
  # :invalid_coordinate_type); keep them stable.
  defp coordinate(value) do
    case LiveCollab.Validation.number(value) do
      {:ok, num} -> {:ok, num}
      {:error, :invalid_number_type} -> {:error, :invalid_coordinate_type}
      {:error, _} -> {:error, :invalid_coordinate_format}
    end
  end

  # Allow slight margins [-0.2, 1.2] for smooth mouse-out tracking before cursor_left triggers
  defp validate_bounds(x, y) do
    cond do
      x < -0.2 or x > 1.2 -> {:error, :coordinate_out_of_bounds}
      y < -0.2 or y > 1.2 -> {:error, :coordinate_out_of_bounds}
      true -> :ok
    end
  end
end
