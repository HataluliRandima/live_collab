defmodule LiveCollab.Presence do
  @moduledoc """
  Presence tracking adapter and collaborative session extraction.

  Wraps an application's existing `Phoenix.Presence` module while handling:
  - Multi-tab tracking per user
  - Deterministic user avatar color and initials generation
  - Presence metadata normalization
  - Atomic field lock updates
  - Shared element and row activity updates
  """

  alias LiveCollab.Config
  alias LiveCollab.Field

  # 12 high-contrast, accessible, visually distinct hex colors for avatar badges
  @default_palette [
    "#4F46E5",
    "#059669",
    "#D97706",
    "#DC2626",
    "#7C3AED",
    "#2563EB",
    "#DB2777",
    "#0891B2",
    "#EA580C",
    "#16A34A",
    "#9333EA",
    "#0D9488"
  ]

  @type user_collab :: %{
          id: String.t() | integer(),
          name: String.t(),
          avatar_url: String.t() | nil,
          color: String.t(),
          initials: String.t(),
          tabs_count: non_neg_integer(),
          active_fields: [String.t()],
          active_elements: [String.t()],
          metas: [map()]
        }

  @doc """
  Tracks a LiveView socket or process in the collaborative presence topic.
  """
  @spec track(
          presence_module :: module(),
          pid_or_socket :: pid() | Phoenix.LiveView.Socket.t(),
          topic :: String.t(),
          user :: map(),
          client_id :: String.t(),
          extra_meta :: map()
        ) :: {:ok, binary()} | {:error, term()}
  def track(presence_module, pid_or_socket, topic, user, client_id, extra_meta \\ %{}) do
    user_id = Map.get(user, :id) || Map.get(user, "id") || client_id
    user_name = Map.get(user, :name) || Map.get(user, "name") || "Guest"
    avatar_url = Map.get(user, :avatar_url) || Map.get(user, "avatar_url")
    color = Map.get(user, :color) || Map.get(user, "color") || deterministic_color(user_id)

    meta =
      %{
        client_id: client_id,
        user_id: user_id,
        user_name: user_name,
        user_avatar: avatar_url,
        user_color: color,
        field: nil,
        acquired_at: 0,
        element: nil,
        element_type: :viewing,
        element_acquired_at: 0
      }
      |> Map.merge(extra_meta)

    presence_module.track(pid_or_socket, topic, to_string(user_id), meta)
  end

  @doc """
  Untracks a process or socket from the collaborative presence topic.
  """
  @spec untrack(
          presence_module :: module(),
          pid_or_socket :: pid() | Phoenix.LiveView.Socket.t(),
          topic :: String.t(),
          user_id :: term()
        ) :: :ok | {:ok, binary()} | {:error, term()}
  def untrack(presence_module, pid_or_socket, topic, user_id) do
    presence_module.untrack(pid_or_socket, topic, to_string(user_id))
  end

  @doc """
  Updates the field currently locked by this client in the presence topic.
  """
  @spec update_field(
          presence_module :: module(),
          pid_or_socket :: pid() | Phoenix.LiveView.Socket.t(),
          topic :: String.t(),
          user_id :: term(),
          field_id :: String.t() | nil,
          client_id :: String.t()
        ) :: {:ok, binary()} | {:error, term()}
  def update_field(presence_module, pid_or_socket, topic, user_id, field_id, client_id) do
    now = System.system_time(:millisecond)

    presence_module.update(pid_or_socket, topic, to_string(user_id), fn existing_meta ->
      acquired_at =
        cond do
          is_nil(field_id) ->
            0

          existing_meta[:field] == field_id and is_integer(existing_meta[:acquired_at]) and
              existing_meta[:acquired_at] > 0 ->
            existing_meta[:acquired_at]

          true ->
            now
        end

      Map.merge(existing_meta, %{
        field: field_id,
        acquired_at: acquired_at,
        client_id: client_id
      })
    end)
  end

  @doc """
  Clears any active field lock for the given client.
  """
  @spec clear_field(
          presence_module :: module(),
          pid_or_socket :: pid() | Phoenix.LiveView.Socket.t(),
          topic :: String.t(),
          user_id :: term(),
          client_id :: String.t()
        ) :: {:ok, binary()} | {:error, term()}
  def clear_field(presence_module, pid_or_socket, topic, user_id, client_id) do
    update_field(presence_module, pid_or_socket, topic, user_id, nil, client_id)
  end

  @doc """
  Updates the element or table-row currently active for this client.
  """
  @spec update_element(
          presence_module :: module(),
          pid_or_socket :: pid() | Phoenix.LiveView.Socket.t(),
          topic :: String.t(),
          user_id :: term(),
          element_id :: String.t() | nil,
          activity_type :: atom(),
          client_id :: String.t()
        ) :: {:ok, binary()} | {:error, term()}
  def update_element(
        presence_module,
        pid_or_socket,
        topic,
        user_id,
        element_id,
        activity_type,
        client_id
      ) do
    now = System.system_time(:millisecond)

    presence_module.update(pid_or_socket, topic, to_string(user_id), fn existing_meta ->
      acquired_at =
        cond do
          is_nil(element_id) ->
            0

          existing_meta[:element] == element_id and
            is_integer(existing_meta[:element_acquired_at]) and
              existing_meta[:element_acquired_at] > 0 ->
            existing_meta[:element_acquired_at]

          true ->
            now
        end

      Map.merge(existing_meta, %{
        element: element_id,
        element_type: activity_type,
        element_acquired_at: acquired_at,
        client_id: client_id
      })
    end)
  end

  @doc """
  Clears any active element activity for the given client.
  """
  @spec clear_element(
          presence_module :: module(),
          pid_or_socket :: pid() | Phoenix.LiveView.Socket.t(),
          topic :: String.t(),
          user_id :: term(),
          client_id :: String.t()
        ) :: {:ok, binary()} | {:error, term()}
  def clear_element(presence_module, pid_or_socket, topic, user_id, client_id) do
    update_element(presence_module, pid_or_socket, topic, user_id, nil, :viewing, client_id)
  end

  @doc """
  Transforms raw `Phoenix.Presence.list/1` output into a list of structured `user_collab` maps.

  Consolidates multiple tabs for the same user while preserving tabs count, active fields,
  and active element locations.
  """
  @spec extract_users(map()) :: [user_collab()]
  def extract_users(presence_entries) when is_map(presence_entries) do
    for {user_id, %{metas: metas}} <- presence_entries, metas != [] do
      first_meta = hd(metas)
      name = Map.get(first_meta, :user_name, "User")
      avatar = Map.get(first_meta, :user_avatar)
      color = Map.get(first_meta, :user_color) || deterministic_color(user_id)

      active_fields =
        metas
        |> Enum.map(&Map.get(&1, :field))
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()

      active_elements =
        metas
        |> Enum.map(&Map.get(&1, :element))
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()

      %{
        id: user_id,
        name: name,
        avatar_url: avatar,
        color: color,
        initials: initials(name),
        tabs_count: length(metas),
        active_fields: active_fields,
        active_elements: active_elements,
        metas: metas
      }
    end
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Generates a deterministic color hex string based on an identifier.
  Ensures consistent color assignment across renders and nodes.
  """
  @spec deterministic_color(term()) :: String.t()
  def deterministic_color(identifier) do
    hash = :erlang.phash2(identifier, length(@default_palette))
    Enum.at(@default_palette, hash)
  end

  @doc """
  Extracts 1 to 2 uppercase initials from a person's display name.
  Falls back to "?" if empty.
  """
  @spec initials(String.t() | nil) :: String.t()
  def initials(nil), do: "?"
  def initials(""), do: "?"

  def initials(name) when is_binary(name) do
    parts =
      name
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    case parts do
      [] ->
        "?"

      [single] ->
        String.slice(single, 0, 2) |> String.upcase()

      [first | rest] ->
        last = List.last(rest)
        first_char = String.slice(first, 0, 1)
        last_char = String.slice(last, 0, 1)
        String.upcase("#{first_char}#{last_char}")
    end
  end
end
