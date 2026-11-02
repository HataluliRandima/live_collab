defmodule LiveCollab.LiveView do
  @moduledoc """
  LiveView integration for LiveCollab.

  Supports automatic lifecycle hooking via `attach_hook/4` as well as
  manual macro inclusion via `use LiveCollab.LiveView`.

  ## Automatic Attachment (Recommended)

      def mount(%{"id" => id}, _session, socket) do
        socket =
          socket
          |> assign(:current_user, current_user)
          |> LiveCollab.track("order:\#{id}", current_user)

        {:ok, socket}
      end

  ## Manual Integration

      use LiveCollab.LiveView, presence: MyApp.Presence
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias LiveCollab.Config
  alias LiveCollab.Cursor
  alias LiveCollab.Element
  alias LiveCollab.Field
  alias LiveCollab.Presence
  alias LiveCollab.Viewport

  @doc """
  Tracks the collaborative session, subscribes to PubSub presence notifications,
  populates initial assigns (`collab_users`, `collab_locks`, `collab_activities`,
  `collab_topic`, `collab_client_id`), and attaches lifecycle hooks to handle
  field focus/blur, element activity, high-frequency cursor/viewport telemetry, and presence diffs.
  """
  @spec track(
          socket :: Phoenix.LiveView.Socket.t(),
          resource :: term(),
          user :: map(),
          opts :: keyword()
        ) :: Phoenix.LiveView.Socket.t()
  def track(socket, resource, user, opts \\ []) do
    config = Config.get(opts)
    presence_mod = config.presence || raise_missing_presence!()
    topic = Config.topic(config, resource)
    pubsub_server = config.pubsub || default_pubsub_server(presence_mod)

    # Each browser tab or client instance generates or is assigned a unique client_id
    client_id = Keyword.get(opts, :client_id, generate_client_id())
    user_id = Map.get(user, :id) || Map.get(user, "id") || client_id
    user_key = to_string(user_id)

    # Only track if socket is connected to avoid tracking static HTTP pre-renders
    socket =
      if connected?(socket) do
        # Subscribe to topic for presence_diff and telemetry notifications
        Phoenix.PubSub.subscribe(pubsub_server, topic)

        # Track this process in Phoenix.Presence
        {:ok, _ref} = Presence.track(presence_mod, socket, topic, user, client_id)

        # Attach LiveView lifecycle hooks for clean, zero-boilerplate event handling
        socket
        |> attach_collab_event_hook(config, presence_mod, user)
        |> attach_collab_info_hook(config, presence_mod, topic)
      else
        socket
      end

    # Fetch initial presence list (or empty map if disconnected)
    presence_entries =
      if connected?(socket), do: presence_mod.list(topic), else: %{}

    users = Presence.extract_users(presence_entries)
    locks = Field.extract_locks(presence_entries)
    activities = Element.extract_activities(presence_entries)

    socket
    |> assign(:collab_topic, topic)
    |> assign(:collab_pubsub, pubsub_server)
    |> assign(:collab_client_id, client_id)
    |> assign(:collab_user_key, user_key)
    |> assign(:collab_users, users)
    |> assign(:collab_locks, locks)
    |> assign(:collab_activities, activities)
    |> assign(:collab_active_element, nil)
    |> assign(:collab_spotlight_leader, nil)
    |> assign(:collab_config, config)
  end

  @doc """
  Untracks collaboration for the current socket and leaves the topic.
  """
  @spec untrack(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def untrack(socket, opts \\ []) do
    topic = socket.assigns[:collab_topic]
    config = socket.assigns[:collab_config] || Config.get(opts)
    presence_mod = config.presence || raise_missing_presence!()

    if connected?(socket) and is_binary(topic) do
      pubsub_server =
        socket.assigns[:collab_pubsub] || config.pubsub || default_pubsub_server(presence_mod)

      user_key =
        socket.assigns[:collab_user_key] ||
          to_string(socket.assigns[:collab_client_id])

      Phoenix.PubSub.unsubscribe(pubsub_server, topic)
      Presence.untrack(presence_mod, socket, topic, user_key)
    end

    socket
    |> assign(:collab_topic, nil)
    |> assign(:collab_user_key, nil)
    |> assign(:collab_users, [])
    |> assign(:collab_locks, %{})
    |> assign(:collab_activities, %{})
    |> assign(:collab_active_element, nil)
    |> assign(:collab_spotlight_leader, nil)
  end

  @doc """
  Updates collaborative assigns and checks for tie-break lock losses.
  Called whenever a `presence_diff` or presence state update occurs.
  """
  @spec handle_presence_sync(
          socket :: Phoenix.LiveView.Socket.t(),
          presence_module :: module(),
          topic :: String.t()
        ) :: Phoenix.LiveView.Socket.t()
  def handle_presence_sync(socket, presence_module, topic) do
    entries = presence_module.list(topic)
    new_users = Presence.extract_users(entries)
    new_locks = Field.extract_locks(entries)
    new_activities = Element.extract_activities(entries)

    current_client_id = socket.assigns[:collab_client_id]
    current_editing_field = socket.assigns[:collab_editing_field]

    # Check if this client was editing a field but lost a deterministic tie-break
    socket =
      if current_editing_field && current_client_id do
        case Map.get(new_locks, current_editing_field) do
          %{client_id: ^current_client_id} ->
            socket

          %{user_name: winner_name} ->
            # Lost tie-break! Notify client hook to blur and switch to locked
            socket
            |> assign(:collab_editing_field, nil)
            |> push_event("live_collab:lock_lost:#{current_editing_field}", %{
              field: current_editing_field,
              locked_by: winner_name
            })
            |> push_event("live_collab:lock_lost", %{
              field: current_editing_field,
              locked_by: winner_name
            })

          nil ->
            socket
        end
      else
        socket
      end

    socket
    |> assign(:collab_users, new_users)
    |> assign(:collab_locks, new_locks)
    |> assign(:collab_activities, new_activities)
  end

  # ============================================================================
  # Authorization & Security Helpers
  # ============================================================================

  @doc """
  Determines if a given socket/user is authorized to lead a spotlight broadcast.
  Rejects unauthenticated clients, explicit false flags, and viewer/observer roles.
  """
  @spec authorized_spotlight_leader?(Phoenix.LiveView.Socket.t(), map()) :: boolean()
  def authorized_spotlight_leader?(socket, user) do
    cond do
      is_nil(socket.assigns[:collab_client_id]) ->
        false

      Map.get(socket.assigns, :collab_can_present?) == false ->
        false

      Map.get(socket.assigns, :can_present?) == false ->
        false

      Map.get(user, :can_present?) == false ->
        false

      Map.get(user, "can_present") == false ->
        false

      Map.get(user, :role) in [:viewer, "viewer", :observer, "observer"] ->
        false

      Map.get(user, "role") in ["viewer", "observer"] ->
        false

      true ->
        true
    end
  end

  @doc """
  Determines if a given client/user is authorized to stop an active spotlight.
  The current spotlight leader or any authorized presenter is permitted to stop it.
  """
  @spec can_stop_spotlight?(Phoenix.LiveView.Socket.t(), map(), String.t() | nil) :: boolean()
  def can_stop_spotlight?(socket, user, client_id) do
    current_leader = socket.assigns[:collab_spotlight_leader]

    cond do
      is_nil(client_id) ->
        false

      is_nil(current_leader) or current_leader == client_id ->
        true

      authorized_spotlight_leader?(socket, user) ->
        true

      true ->
        false
    end
  end

  # ============================================================================
  # Internal Lifecycle Hooks
  # ============================================================================

  defp attach_collab_event_hook(socket, config, presence_mod, user) do
    attach_hook(socket, :live_collab_events, :handle_event, fn
      "live_collab:field_focus", %{"field" => raw_field}, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          case Field.validate_field_id(raw_field, config.max_field_id_length) do
            {:ok, field_id} ->
              topic = sock.assigns.collab_topic

              user_key =
                sock.assigns[:collab_user_key] ||
                  to_string(Map.get(user, :id) || Map.get(user, "id") || client_id)

              # Atomic update in Presence
              Presence.update_field(presence_mod, sock, topic, user_key, field_id, client_id)

              {:halt, assign(sock, :collab_editing_field, field_id)}

            {:error, _reason} ->
              {:halt, sock}
          end
        end

      "live_collab:field_blur", _params, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          topic = sock.assigns.collab_topic

          user_key =
            sock.assigns[:collab_user_key] ||
              to_string(Map.get(user, :id) || Map.get(user, "id") || client_id)

          Presence.clear_field(presence_mod, sock, topic, user_key, client_id)

          {:halt, assign(sock, :collab_editing_field, nil)}
        end

      "live_collab:element_active", %{"element" => raw_element} = params, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          case Element.validate_element_id(raw_element, config.max_field_id_length) do
            {:ok, element_id} ->
              type = Element.normalize_activity_type(params["type"])
              topic = sock.assigns.collab_topic

              user_key =
                sock.assigns[:collab_user_key] ||
                  to_string(Map.get(user, :id) || Map.get(user, "id") || client_id)

              Presence.update_element(
                presence_mod,
                sock,
                topic,
                user_key,
                element_id,
                type,
                client_id
              )

              {:halt, assign(sock, :collab_active_element, element_id)}

            {:error, _reason} ->
              {:halt, sock}
          end
        end

      "live_collab:element_inactive", _params, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          topic = sock.assigns.collab_topic

          user_key =
            sock.assigns[:collab_user_key] ||
              to_string(Map.get(user, :id) || Map.get(user, "id") || client_id)

          Presence.clear_element(presence_mod, sock, topic, user_key, client_id)

          {:halt, assign(sock, :collab_active_element, nil)}
        end

      # High-Frequency Ephemeral Cursor Telemetry (Path 2: Zero Assigns Diffing)
      "live_collab:cursor_move", %{"x" => x, "y" => y} = params, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          case Cursor.validate_coordinates(x, y) do
            {:ok, nx, ny} ->
              topic = sock.assigns.collab_topic
              pubsub = sock.assigns[:collab_pubsub] || default_pubsub_server(presence_mod)
              container_id = params["container_id"]
              payload = Cursor.build_payload(client_id, user, nx, ny, container_id)

              Phoenix.PubSub.broadcast(pubsub, topic, {:collab_cursor_moved, topic, payload})
              {:halt, sock}

            {:error, _reason} ->
              {:halt, sock}
          end
        end

      "live_collab:cursor_left", params, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          topic = sock.assigns.collab_topic
          pubsub = sock.assigns[:collab_pubsub] || default_pubsub_server(presence_mod)
          container_id = params["container_id"]

          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            {:collab_cursor_left, topic,
             %{client_id: client_id, container_id: container_id}}
          )

          {:halt, sock}
        end

      # High-Frequency Viewport & Scroll Following (Path 2)
      "live_collab:viewport_move",
      %{"scroll_x" => sx, "scroll_y" => sy} = params,
      sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          zoom = params["zoom"] || 1.0

          case Viewport.validate_viewport(sx, sy, zoom) do
            {:ok, nsx, nsy, nzoom} ->
              topic = sock.assigns.collab_topic
              pubsub = sock.assigns[:collab_pubsub] || default_pubsub_server(presence_mod)

              payload =
                Viewport.build_viewport_payload(client_id, user, nsx, nsy,
                  zoom: nzoom,
                  container_id: params["container_id"],
                  anchor_element_id: params["anchor_element_id"]
                )

              Phoenix.PubSub.broadcast(pubsub, topic, {:collab_viewport_moved, topic, payload})
              {:halt, sock}

            {:error, _reason} ->
              {:halt, sock}
          end
        end

      "live_collab:spotlight_lead", _params, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) or not authorized_spotlight_leader?(sock, user) do
          {:halt, push_event(sock, "live_collab:spotlight_unauthorized", %{reason: "unauthorized"})}
        else
          topic = sock.assigns.collab_topic
          pubsub = sock.assigns[:collab_pubsub] || default_pubsub_server(presence_mod)
          user_name = Map.get(user, :name) || Map.get(user, "name") || "Leader"

          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            {:collab_spotlight_status, topic,
             %{
               client_id: client_id,
               user_id: Map.get(user, :id) || client_id,
               user_name: user_name,
               active: true
             }}
          )

          {:halt, assign(sock, :collab_spotlight_leader, client_id)}
        end

      "live_collab:spotlight_stop", _params, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) or not can_stop_spotlight?(sock, user, client_id) do
          {:halt, sock}
        else
          topic = sock.assigns.collab_topic
          pubsub = sock.assigns[:collab_pubsub] || default_pubsub_server(presence_mod)

          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            {:collab_spotlight_status, topic, %{client_id: client_id, active: false}}
          )

          {:halt, assign(sock, :collab_spotlight_leader, nil)}
        end

      # Multiplayer Selection Bounding Boxes (Path 2)
      "live_collab:selection_move",
      %{"x" => x, "y" => y, "width" => w, "height" => h} = params,
      sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          case Viewport.validate_selection(x, y, w, h) do
            {:ok, nx, ny, nw, nh} ->
              topic = sock.assigns.collab_topic
              pubsub = sock.assigns[:collab_pubsub] || default_pubsub_server(presence_mod)

              payload =
                Viewport.build_selection_payload(client_id, user, nx, ny, nw, nh,
                  container_id: params["container_id"],
                  selected_ids: params["selected_ids"] || []
                )

              Phoenix.PubSub.broadcast(pubsub, topic, {:collab_selection_moved, topic, payload})
              {:halt, sock}

            {:error, _reason} ->
              {:halt, sock}
          end
        end

      "live_collab:selection_clear", params, sock ->
        client_id = sock.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:halt, sock}
        else
          topic = sock.assigns.collab_topic
          pubsub = sock.assigns[:collab_pubsub] || default_pubsub_server(presence_mod)

          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            {:collab_selection_cleared, topic,
             %{client_id: client_id, container_id: params["container_id"]}}
          )

          {:halt, sock}
        end

      _other_event, _params, sock ->
        {:cont, sock}
    end)
  end

  defp attach_collab_info_hook(socket, _config, presence_mod, topic) do
    attach_hook(socket, :live_collab_info, :handle_info, fn
      %Phoenix.Socket.Broadcast{event: "presence_diff", topic: ^topic}, sock ->
        {:halt, handle_presence_sync(sock, presence_mod, topic)}

      # High-Frequency Ephemeral Telemetry (Zero Assigns Diffing)
      {:collab_cursor_moved, ^topic, payload}, sock ->
        if payload[:client_id] != sock.assigns[:collab_client_id] do
          {:halt, push_event(sock, "live_collab:cursor_moved", payload)}
        else
          {:halt, sock}
        end

      {:collab_cursor_left, ^topic, payload}, sock ->
        if payload[:client_id] != sock.assigns[:collab_client_id] do
          {:halt, push_event(sock, "live_collab:cursor_left", payload)}
        else
          {:halt, sock}
        end

      {:collab_viewport_moved, ^topic, payload}, sock ->
        if payload[:client_id] != sock.assigns[:collab_client_id] do
          {:halt, push_event(sock, "live_collab:viewport_moved", payload)}
        else
          {:halt, sock}
        end

      {:collab_spotlight_status, ^topic, payload}, sock ->
        leader = if payload[:active], do: payload[:client_id], else: nil
        sock = assign(sock, :collab_spotlight_leader, leader)

        if payload[:client_id] != sock.assigns[:collab_client_id] do
          {:halt, push_event(sock, "live_collab:spotlight_status", payload)}
        else
          {:halt, sock}
        end

      {:collab_selection_moved, ^topic, payload}, sock ->
        if payload[:client_id] != sock.assigns[:collab_client_id] do
          {:halt, push_event(sock, "live_collab:selection_moved", payload)}
        else
          {:halt, sock}
        end

      {:collab_selection_cleared, ^topic, payload}, sock ->
        if payload[:client_id] != sock.assigns[:collab_client_id] do
          {:halt, push_event(sock, "live_collab:selection_cleared", payload)}
        else
          {:halt, sock}
        end

      _other_msg, sock ->
        {:cont, sock}
    end)
  end

  defp generate_client_id do
    "cli_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp default_pubsub_server(presence_mod) do
    try do
      # Phoenix.Presence modules typically expose __pubsub_server__/0
      presence_mod.__pubsub_server__()
    rescue
      _ ->
        Config.get().pubsub ||
          raise(
            ArgumentError,
            "Could not determine PubSub server. Please configure config :live_collab, pubsub: MyApp.PubSub"
          )
    end
  end

  defp raise_missing_presence!() do
    raise ArgumentError, """
    LiveCollab requires a Phoenix.Presence module to be configured.

    Configure in config/config.exs:
        config :live_collab, presence: MyAppWeb.Presence

    Or pass as an option to LiveCollab.track(socket, resource, user, presence: MyAppWeb.Presence)
    """
  end

  defmacro __using__(opts) do
    quote do
      import LiveCollab.Components

      def handle_event("live_collab:field_focus", %{"field" => field}, socket) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          presence_mod = config.presence
          topic = socket.assigns.collab_topic
          user = socket.assigns[:current_user] || %{}

          user_key =
            socket.assigns[:collab_user_key] ||
              to_string(Map.get(user, :id) || Map.get(user, "id") || client_id)

          case LiveCollab.Field.validate_field_id(field, config.max_field_id_length) do
            {:ok, field_id} ->
              LiveCollab.Presence.update_field(
                presence_mod,
                socket,
                topic,
                user_key,
                field_id,
                client_id
              )

              {:noreply, assign(socket, :collab_editing_field, field_id)}

            {:error, _} ->
              {:noreply, socket}
          end
        end
      end

      def handle_event("live_collab:field_blur", _params, socket) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          presence_mod = config.presence
          topic = socket.assigns.collab_topic
          user = socket.assigns[:current_user] || %{}

          user_key =
            socket.assigns[:collab_user_key] ||
              to_string(Map.get(user, :id) || Map.get(user, "id") || client_id)

          LiveCollab.Presence.clear_field(presence_mod, socket, topic, user_key, client_id)

          {:noreply, assign(socket, :collab_editing_field, nil)}
        end
      end

      def handle_event("live_collab:element_active", %{"element" => element} = params, socket) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          presence_mod = config.presence
          topic = socket.assigns.collab_topic
          user = socket.assigns[:current_user] || %{}

          user_key =
            socket.assigns[:collab_user_key] ||
              to_string(Map.get(user, :id) || Map.get(user, "id") || client_id)

          case LiveCollab.Element.validate_element_id(element, config.max_field_id_length) do
            {:ok, element_id} ->
              type = LiveCollab.Element.normalize_activity_type(params["type"])

              LiveCollab.Presence.update_element(
                presence_mod,
                socket,
                topic,
                user_key,
                element_id,
                type,
                client_id
              )

              {:noreply, assign(socket, :collab_active_element, element_id)}

            {:error, _} ->
              {:noreply, socket}
          end
        end
      end

      def handle_event("live_collab:element_inactive", _params, socket) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          presence_mod = config.presence
          topic = socket.assigns.collab_topic
          user = socket.assigns[:current_user] || %{}

          user_key =
            socket.assigns[:collab_user_key] ||
              to_string(Map.get(user, :id) || Map.get(user, "id") || client_id)

          LiveCollab.Presence.clear_element(presence_mod, socket, topic, user_key, client_id)

          {:noreply, assign(socket, :collab_active_element, nil)}
        end
      end

      def handle_event("live_collab:cursor_move", %{"x" => x, "y" => y} = params, socket) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          user = socket.assigns[:current_user] || %{}

          case LiveCollab.Cursor.validate_coordinates(x, y) do
            {:ok, nx, ny} ->
              topic = socket.assigns.collab_topic

              pubsub =
                socket.assigns[:collab_pubsub] || config.pubsub ||
                  LiveCollab.LiveView.default_pubsub_server(config.presence)

              container_id = params["container_id"]
              payload = LiveCollab.Cursor.build_payload(client_id, user, nx, ny, container_id)

              Phoenix.PubSub.broadcast(pubsub, topic, {:collab_cursor_moved, topic, payload})
              {:noreply, socket}

            {:error, _} ->
              {:noreply, socket}
          end
        end
      end

      def handle_event("live_collab:cursor_left", params, socket) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          topic = socket.assigns.collab_topic

          pubsub =
            socket.assigns[:collab_pubsub] || config.pubsub ||
              LiveCollab.LiveView.default_pubsub_server(config.presence)

          container_id = params["container_id"]

          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            {:collab_cursor_left, topic, %{client_id: client_id, container_id: container_id}}
          )

          {:noreply, socket}
        end
      end

      def handle_event(
            "live_collab:viewport_move",
            %{"scroll_x" => sx, "scroll_y" => sy} = params,
            socket
          ) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          user = socket.assigns[:current_user] || %{}
          zoom = params["zoom"] || 1.0

          case LiveCollab.Viewport.validate_viewport(sx, sy, zoom) do
            {:ok, nsx, nsy, nzoom} ->
              topic = socket.assigns.collab_topic

              pubsub =
                socket.assigns[:collab_pubsub] || config.pubsub ||
                  LiveCollab.LiveView.default_pubsub_server(config.presence)

              payload =
                LiveCollab.Viewport.build_viewport_payload(client_id, user, nsx, nsy,
                  zoom: nzoom,
                  container_id: params["container_id"],
                  anchor_element_id: params["anchor_element_id"]
                )

              Phoenix.PubSub.broadcast(pubsub, topic, {:collab_viewport_moved, topic, payload})
              {:noreply, socket}

            {:error, _} ->
              {:noreply, socket}
          end
        end
      end

      def handle_event("live_collab:spotlight_lead", _params, socket) do
        client_id = socket.assigns[:collab_client_id]
        user = socket.assigns[:current_user] || %{}

        if is_nil(client_id) or not LiveCollab.LiveView.authorized_spotlight_leader?(socket, user) do
          {:noreply, push_event(socket, "live_collab:spotlight_unauthorized", %{reason: "unauthorized"})}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          topic = socket.assigns.collab_topic

          pubsub =
            socket.assigns[:collab_pubsub] || config.pubsub ||
              LiveCollab.LiveView.default_pubsub_server(config.presence)

          user_name = Map.get(user, :name) || Map.get(user, "name") || "Leader"

          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            {:collab_spotlight_status, topic,
             %{
               client_id: client_id,
               user_id: Map.get(user, :id) || client_id,
               user_name: user_name,
               active: true
             }}
          )

          {:noreply, assign(socket, :collab_spotlight_leader, client_id)}
        end
      end

      def handle_event("live_collab:spotlight_stop", _params, socket) do
        client_id = socket.assigns[:collab_client_id]
        user = socket.assigns[:current_user] || %{}

        if is_nil(client_id) or not LiveCollab.LiveView.can_stop_spotlight?(socket, user, client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          topic = socket.assigns.collab_topic

          pubsub =
            socket.assigns[:collab_pubsub] || config.pubsub ||
              LiveCollab.LiveView.default_pubsub_server(config.presence)

          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            {:collab_spotlight_status, topic, %{client_id: client_id, active: false}}
          )

          {:noreply, assign(socket, :collab_spotlight_leader, nil)}
        end
      end

      def handle_event(
            "live_collab:selection_move",
            %{"x" => x, "y" => y, "width" => w, "height" => h} = params,
            socket
          ) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          user = socket.assigns[:current_user] || %{}

          case LiveCollab.Viewport.validate_selection(x, y, w, h) do
            {:ok, nx, ny, nw, nh} ->
              topic = socket.assigns.collab_topic

              pubsub =
                socket.assigns[:collab_pubsub] || config.pubsub ||
                  LiveCollab.LiveView.default_pubsub_server(config.presence)

              payload =
                LiveCollab.Viewport.build_selection_payload(client_id, user, nx, ny, nw, nh,
                  container_id: params["container_id"],
                  selected_ids: params["selected_ids"] || []
                )

              Phoenix.PubSub.broadcast(pubsub, topic, {:collab_selection_moved, topic, payload})
              {:noreply, socket}

            {:error, _} ->
              {:noreply, socket}
          end
        end
      end

      def handle_event("live_collab:selection_clear", params, socket) do
        client_id = socket.assigns[:collab_client_id]

        if is_nil(client_id) do
          {:noreply, socket}
        else
          config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
          topic = socket.assigns.collab_topic

          pubsub =
            socket.assigns[:collab_pubsub] || config.pubsub ||
              LiveCollab.LiveView.default_pubsub_server(config.presence)

          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            {:collab_selection_cleared, topic,
             %{client_id: client_id, container_id: params["container_id"]}}
          )

          {:noreply, socket}
        end
      end

      def handle_info(
            %Phoenix.Socket.Broadcast{
              event: "presence_diff",
              topic: topic
            },
            socket
          )
          when topic == socket.assigns.collab_topic do
        config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
        {:noreply, LiveCollab.LiveView.handle_presence_sync(socket, config.presence, topic)}
      end

      def handle_info({:collab_cursor_moved, topic, payload}, socket)
          when topic == socket.assigns.collab_topic do
        if payload[:client_id] != socket.assigns[:collab_client_id] do
          {:noreply, push_event(socket, "live_collab:cursor_moved", payload)}
        else
          {:noreply, socket}
        end
      end

      def handle_info({:collab_cursor_left, topic, payload}, socket)
          when topic == socket.assigns.collab_topic do
        if payload[:client_id] != socket.assigns[:collab_client_id] do
          {:noreply, push_event(socket, "live_collab:cursor_left", payload)}
        else
          {:noreply, socket}
        end
      end

      def handle_info({:collab_viewport_moved, topic, payload}, socket)
          when topic == socket.assigns.collab_topic do
        if payload[:client_id] != socket.assigns[:collab_client_id] do
          {:noreply, push_event(socket, "live_collab:viewport_moved", payload)}
        else
          {:noreply, socket}
        end
      end

      def handle_info({:collab_spotlight_status, topic, payload}, socket)
          when topic == socket.assigns.collab_topic do
        leader = if payload[:active], do: payload[:client_id], else: nil
        socket = assign(socket, :collab_spotlight_leader, leader)

        if payload[:client_id] != socket.assigns[:collab_client_id] do
          {:noreply, push_event(socket, "live_collab:spotlight_status", payload)}
        else
          {:noreply, socket}
        end
      end

      def handle_info({:collab_selection_moved, topic, payload}, socket)
          when topic == socket.assigns.collab_topic do
        if payload[:client_id] != socket.assigns[:collab_client_id] do
          {:noreply, push_event(socket, "live_collab:selection_moved", payload)}
        else
          {:noreply, socket}
        end
      end

      def handle_info({:collab_selection_cleared, topic, payload}, socket)
          when topic == socket.assigns.collab_topic do
        if payload[:client_id] != socket.assigns[:collab_client_id] do
          {:noreply, push_event(socket, "live_collab:selection_cleared", payload)}
        else
          {:noreply, socket}
        end
      end
    end
  end
end
