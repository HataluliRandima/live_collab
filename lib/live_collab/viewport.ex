defmodule LiveCollab.Viewport do
  @moduledoc """
  Telemetry manager for viewport/scroll following and multiplayer selection containers.

  Like collaborative cursors (Path 2), viewport and selection telemetry are high-frequency
  ephemeral events that bypass `Phoenix.Presence` and LiveView's assigns/diff engine completely:
  - Broadcast over `Phoenix.PubSub`
  - Pushed to browser clients via `Phoenix.LiveView.push_event/3`
  - Zero LiveView template re-renders or DOM diff computations
  - Rendered client-side via hardware-accelerated CSS transforms and smooth programmatic scrolling.

  ## Viewport Normalization

  To support differing viewport sizes, window dimensions, and monitor aspect ratios,
  scroll positions are expressed as normalized percentages in `[0.0, 1.0]`:

      scroll_x_pct = scroll_left / max(scroll_width - client_width, 1)
      scroll_y_pct = scroll_top / max(scroll_height - client_height, 1)

  This allows a presenter on a 4K display to lead followers on 13" laptops smoothly
  to the exact proportional location in the document or canvas.

  ## Selection Bounding Boxes

  Selection containers represent collaborative regions currently selected or dragged
  by a user in a canvas, document, or grid, bounded by `{x, y, width, height}` in normalized
  container coordinates.
  """

  @type normalized_pct :: float()

  @type viewport_payload :: %{
          required(:client_id) => String.t(),
          required(:user_id) => String.t() | integer(),
          required(:user_name) => String.t(),
          required(:user_color) => String.t(),
          required(:scroll_x) => normalized_pct(),
          required(:scroll_y) => normalized_pct(),
          required(:zoom) => float(),
          optional(:container_id) => String.t() | nil,
          optional(:anchor_element_id) => String.t() | nil,
          required(:timestamp) => integer()
        }

  @type selection_payload :: %{
          required(:client_id) => String.t(),
          required(:user_id) => String.t() | integer(),
          required(:user_name) => String.t(),
          required(:user_color) => String.t(),
          required(:x) => float(),
          required(:y) => float(),
          required(:width) => float(),
          required(:height) => float(),
          optional(:container_id) => String.t() | nil,
          optional(:selected_ids) => [String.t()],
          required(:timestamp) => integer()
        }

  @doc """
  Validates incoming scroll and viewport coordinates.

  Ensures coordinates are:
  - Valid finite numbers
  - Within allowable bounds (`0.0 <= val <= 1.0` for scroll percentages, with slight margin `[-0.1, 1.1]`)
  - Zoom level within reasonable range (`0.1 <= zoom <= 10.0`)
  """
  @spec validate_viewport(term(), term(), term()) ::
          {:ok, float(), float(), float()} | {:error, atom()}
  def validate_viewport(scroll_x, scroll_y, zoom \\ 1.0) do
    with {:ok, nx} <- parse_number(scroll_x),
         {:ok, ny} <- parse_number(scroll_y),
         {:ok, nz} <- parse_number(zoom),
         :ok <- validate_scroll_bounds(nx, ny),
         :ok <- validate_zoom_bounds(nz) do
      {:ok, nx, ny, nz}
    end
  end

  @doc """
  Validates incoming multiplayer selection bounding box coordinates.

  Coordinates `x`, `y`, `width`, `height` must be finite numbers with `width >= 0` and `height >= 0`.
  """
  @spec validate_selection(term(), term(), term(), term()) ::
          {:ok, float(), float(), float(), float()} | {:error, atom()}
  def validate_selection(x, y, width, height) do
    with {:ok, nx} <- parse_number(x),
         {:ok, ny} <- parse_number(y),
         {:ok, nw} <- parse_number(width),
         {:ok, nh} <- parse_number(height),
         :ok <- validate_selection_bounds(nx, ny, nw, nh) do
      {:ok, nx, ny, nw, nh}
    end
  end

  @doc """
  Sanitizes and constructs a broadcast viewport payload.
  """
  @spec build_viewport_payload(
          client_id :: String.t(),
          user :: map(),
          scroll_x :: float(),
          scroll_y :: float(),
          opts :: keyword()
        ) :: viewport_payload()
  def build_viewport_payload(client_id, user, scroll_x, scroll_y, opts \\ []) do
    user_id = Map.get(user, :id) || Map.get(user, "id") || client_id
    user_name = Map.get(user, :name) || Map.get(user, "name") || "Collaborator"

    user_color =
      Map.get(user, :color) || Map.get(user, "color") ||
        LiveCollab.Presence.deterministic_color(user_id)

    zoom = Keyword.get(opts, :zoom, 1.0)
    container_id = Keyword.get(opts, :container_id)
    anchor_element_id = Keyword.get(opts, :anchor_element_id)

    %{
      client_id: client_id,
      user_id: user_id,
      user_name: user_name,
      user_color: user_color,
      scroll_x: Float.round(scroll_x * 1.0, 4),
      scroll_y: Float.round(scroll_y * 1.0, 4),
      zoom: Float.round(zoom * 1.0, 2),
      container_id: container_id,
      anchor_element_id: anchor_element_id,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Sanitizes and constructs a broadcast selection bounding box payload.
  """
  @spec build_selection_payload(
          client_id :: String.t(),
          user :: map(),
          x :: float(),
          y :: float(),
          width :: float(),
          height :: float(),
          opts :: keyword()
        ) :: selection_payload()
  def build_selection_payload(client_id, user, x, y, width, height, opts \\ []) do
    user_id = Map.get(user, :id) || Map.get(user, "id") || client_id
    user_name = Map.get(user, :name) || Map.get(user, "name") || "Collaborator"

    user_color =
      Map.get(user, :color) || Map.get(user, "color") ||
        LiveCollab.Presence.deterministic_color(user_id)

    container_id = Keyword.get(opts, :container_id)
    selected_ids = Keyword.get(opts, :selected_ids, [])

    %{
      client_id: client_id,
      user_id: user_id,
      user_name: user_name,
      user_color: user_color,
      x: Float.round(x * 1.0, 4),
      y: Float.round(y * 1.0, 4),
      width: Float.round(width * 1.0, 4),
      height: Float.round(height * 1.0, 4),
      container_id: container_id,
      selected_ids: selected_ids,
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
    not (num > 1.0e308 or num < -1.0e308 or num != num)
  end

  defp validate_scroll_bounds(x, y) do
    cond do
      x < -0.1 or x > 1.1 -> {:error, :scroll_out_of_bounds}
      y < -0.1 or y > 1.1 -> {:error, :scroll_out_of_bounds}
      true -> :ok
    end
  end

  defp validate_zoom_bounds(zoom) do
    if zoom >= 0.1 and zoom <= 10.0 do
      :ok
    else
      {:error, :zoom_out_of_bounds}
    end
  end

  defp validate_selection_bounds(x, y, w, h) do
    cond do
      w < 0.0 or h < 0.0 -> {:error, :negative_dimensions}
      x < -0.5 or x > 1.5 -> {:error, :selection_out_of_bounds}
      y < -0.5 or y > 1.5 -> {:error, :selection_out_of_bounds}
      true -> :ok
    end
  end
end

