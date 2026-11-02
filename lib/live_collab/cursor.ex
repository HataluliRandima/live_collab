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
    with {:ok, nx} <- parse_number(x),
         {:ok, ny} <- parse_number(y),
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
    user_id = Map.get(user, :id) || Map.get(user, "id") || client_id
    user_name = Map.get(user, :name) || Map.get(user, "name") || "Collaborator"

    user_color =
      Map.get(user, :color) || Map.get(user, "color") ||
        LiveCollab.Presence.deterministic_color(user_id)

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

  defp parse_number(val) when is_float(val) do
    if is_finite(val), do: {:ok, val}, else: {:error, :non_finite_number}
  end

  defp parse_number(val) when is_integer(val) do
    {:ok, val * 1.0}
  end

  defp parse_number(val) when is_binary(val) do
    case Float.parse(val) do
      {num, ""} -> parse_number(num)
      _ -> {:error, :invalid_coordinate_format}
    end
  end

  defp parse_number(_invalid), do: {:error, :invalid_coordinate_type}

  defp is_finite(num) when is_float(num) do
    # In Erlang/Elixir, floats can be checked against infinity / NaN
    not (num > 1.0e308 or num < -1.0e308 or num != num)
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

