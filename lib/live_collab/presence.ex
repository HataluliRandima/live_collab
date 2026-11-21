defmodule LiveCollab.Presence do
  @moduledoc """
  Presence tracking adapter and collaborative session extraction.

  Wraps an application's existing `Phoenix.Presence` module while handling:
  - Multi-tab tracking per user
  - Deterministic user avatar color and initials generation
  - Presence metadata normalization
  - Atomic field lock updates
  - Shared element and row activity updates

  ## Process identity

  `Phoenix.Presence` tracks *processes*. Every function here that accepts
  `pid_or_socket` resolves a LiveView socket to `self()`, so it must be called
  from the LiveView process that owns the socket (which is always the case in
  LiveView callbacks and lifecycle hooks). Pids are passed through unchanged.
  """

  alias LiveCollab.Validation

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
          status: status(),
          metas: [map()]
        }

  @typedoc "Activity status of a tab (`:away` when hidden or idle)."
  @type status :: :active | :away

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
    identity = identity(user, client_id)

    meta =
      %{
        client_id: client_id,
        user_id: identity.id,
        user_name: identity.name,
        user_avatar: identity.avatar_url,
        user_color: identity.color,
        field: nil,
        acquired_at: 0,
        element: nil,
        element_type: :viewing,
        element_acquired_at: 0,
        status: :active
      }
      |> Map.merge(extra_meta)

    presence_module.track(to_pid(pid_or_socket), topic, identity.key, meta)
  end

  @typedoc "Normalized, display-safe identity derived from an application user map."
  @type identity :: %{
          id: term(),
          key: String.t(),
          name: String.t(),
          avatar_url: String.t() | nil,
          color: String.t()
        }

  @doc """
  Derives the identity LiveCollab publishes for a user.

  Accepts atom or string keys (`:id`, `:name`, `:avatar_url`, `:color`). Falls
  back to `client_id` when the user has no id and to `"Guest"` when it has no
  name. Colors that are not `#rgb`/`#rrggbb` are replaced by
  `deterministic_color/1`; avatar URLs that are not `http(s)`, root-relative or
  `data:image/` are dropped.
  """
  @spec identity(map(), String.t()) :: identity()
  def identity(user, client_id) when is_map(user) do
    id = user_field(user, :id) || client_id
    name = user_field(user, :name)

    avatar_url =
      case Validation.avatar_url(user_field(user, :avatar_url)) do
        {:ok, url} -> url
        {:error, _} -> nil
      end

    %{
      id: id,
      key: to_string(id),
      name: if(is_binary(name) and name != "", do: name, else: "Guest"),
      avatar_url: avatar_url,
      color: safe_color(user_field(user, :color), id)
    }
  end

  @doc """
  Returns `color` normalized to `#rrggbb` when it is a valid hex color, otherwise
  the deterministic palette color for `identifier`.
  """
  @spec safe_color(term(), term()) :: String.t()
  def safe_color(color, identifier) do
    case Validation.color(color) do
      {:ok, hex} -> hex
      {:error, _} -> deterministic_color(identifier)
    end
  end

  @doc false
  # `{id, name, color}` for telemetry payloads. Accepts a raw user map or an
  # `identity/2` map (both expose `:id`, `:name`, `:color`).
  @spec display_fields(map(), String.t()) :: {term(), String.t(), String.t()}
  def display_fields(user, client_id) when is_map(user) do
    id = user_field(user, :id) || client_id
    name = user_field(user, :name)
    name = if is_binary(name) and name != "", do: name, else: "Collaborator"
    {id, name, safe_color(user_field(user, :color), id)}
  end

  defp user_field(user, key) do
    case Map.get(user, key) do
      nil -> Map.get(user, Atom.to_string(key))
      value -> value
    end
  end

  defp to_pid(pid) when is_pid(pid), do: pid
  defp to_pid(%Phoenix.LiveView.Socket{}), do: self()

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
    presence_module.untrack(to_pid(pid_or_socket), topic, to_string(user_id))
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

    presence_module.update(to_pid(pid_or_socket), topic, to_string(user_id), fn existing_meta ->
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

    presence_module.update(to_pid(pid_or_socket), topic, to_string(user_id), fn existing_meta ->
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
  Sets this tab's activity status (`:active` or `:away`) in Presence.

  Must be called from the LiveView process that tracked the presence.
  """
  @spec update_status(
          presence_module :: module(),
          pid_or_socket :: pid() | Phoenix.LiveView.Socket.t(),
          topic :: String.t(),
          user_id :: term(),
          status :: status()
        ) :: {:ok, binary()} | {:error, term()}
  def update_status(presence_module, pid_or_socket, topic, user_id, status)
      when status in [:active, :away] do
    presence_module.update(to_pid(pid_or_socket), topic, to_string(user_id), fn meta ->
      Map.put(meta, :status, status)
    end)
  end

  @doc """
  Transforms raw `c:Phoenix.Presence.list/1` output into a list of structured `user_collab` maps.

  Consolidates multiple tabs for the same user while preserving tabs count, active fields,
  and active element locations. A user is `:away` only when every one of their
  tabs is away; metas without a status (e.g. from older nodes) count as active.
  """
  @spec extract_users(map()) :: [user_collab()]
  def extract_users(presence_entries) when is_map(presence_entries) do
    for {user_id, %{metas: metas}} <- presence_entries, metas != [] do
      first_meta = hd(metas)
      name = Map.get(first_meta, :user_name, "User")
      avatar = Map.get(first_meta, :user_avatar)
      # Colors are sanitized where they enter (track/6) and where they leave
      # (components, JS hooks); extraction runs per rebuild, so it stays cheap.
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
        status: user_status(metas),
        metas: metas
      }
    end
    |> Enum.sort_by(& &1.name)
  end

  defp user_status(metas) do
    if Enum.all?(metas, &(Map.get(&1, :status) == :away)), do: :away, else: :active
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
    # String.split/1 splits on Unicode whitespace and drops empty parts.
    parts = String.split(name)

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
