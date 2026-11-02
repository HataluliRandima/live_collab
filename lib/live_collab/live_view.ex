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
          |> LiveCollab.track("order:#{id}", current_user)

        {:ok, socket}
      end

  ## Manual Integration

      use LiveCollab.LiveView, presence: MyApp.Presence
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias LiveCollab.Config
  alias LiveCollab.Element
  alias LiveCollab.Field
  alias LiveCollab.Presence

  @doc """
  Tracks the collaborative session, subscribes to PubSub presence notifications,
  populates initial assigns (`collab_users`, `collab_locks`, `collab_activities`,
  `collab_topic`, `collab_client_id`), and attaches lifecycle hooks to handle
  field focus/blur, element activity, and presence diffs.
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

    # Each browser tab or client instance generates or is assigned a unique client_id
    client_id = Keyword.get(opts, :client_id, generate_client_id())

    # Only track if socket is connected to avoid tracking static HTTP pre-renders
    socket =
      if connected?(socket) do
        # Subscribe to topic for presence_diff notifications
        pubsub_server = config.pubsub || default_pubsub_server(presence_mod)
        Phoenix.PubSub.subscribe(pubsub_server, topic)

        # Track this process in Phoenix.Presence
        {:ok, _ref} = Presence.track(presence_mod, socket, topic, user, client_id)

        # Attach LiveView lifecycle hooks for clean, zero-boilerplate event handling
        socket
        |> attach_collab_event_hook(config, presence_mod, topic, user)
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
    |> assign(:collab_client_id, client_id)
    |> assign(:collab_users, users)
    |> assign(:collab_locks, locks)
    |> assign(:collab_activities, activities)
    |> assign(:collab_active_element, nil)
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
      pubsub_server = config.pubsub || default_pubsub_server(presence_mod)
      Phoenix.PubSub.unsubscribe(pubsub_server, topic)
      presence_mod.untrack(socket, topic, to_string(socket.assigns[:collab_client_id]))
    end

    socket
    |> assign(:collab_topic, nil)
    |> assign(:collab_users, [])
    |> assign(:collab_locks, %{})
    |> assign(:collab_activities, %{})
    |> assign(:collab_active_element, nil)
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
  # Internal Lifecycle Hooks
  # ============================================================================

  defp attach_collab_event_hook(socket, config, presence_mod, user) do
    attach_hook(socket, :live_collab_events, :handle_event, fn
      "live_collab:field_focus", %{"field" => raw_field} = params, sock ->
        client_id = params["client_id"] || sock.assigns[:collab_client_id]

        case Field.validate_field_id(raw_field, config.max_field_id_length) do
          {:ok, field_id} ->
            topic = sock.assigns.collab_topic
            user_id = Map.get(user, :id) || Map.get(user, "id") || client_id

            # Atomic update in Presence
            Presence.update_field(presence_mod, sock, topic, user_id, field_id, client_id)

            {:halt, assign(sock, :collab_editing_field, field_id)}

          {:error, _reason} ->
            {:halt, sock}
        end

      "live_collab:field_blur", params, sock ->
        client_id = params["client_id"] || sock.assigns[:collab_client_id]
        topic = sock.assigns.collab_topic
        user_id = Map.get(user, :id) || Map.get(user, "id") || client_id

        Presence.clear_field(presence_mod, sock, topic, user_id, client_id)

        {:halt, assign(sock, :collab_editing_field, nil)}

      "live_collab:element_active", %{"element" => raw_element} = params, sock ->
        client_id = params["client_id"] || sock.assigns[:collab_client_id]

        case Element.validate_element_id(raw_element, config.max_field_id_length) do
          {:ok, element_id} ->
            type = Element.normalize_activity_type(params["type"])
            topic = sock.assigns.collab_topic
            user_id = Map.get(user, :id) || Map.get(user, "id") || client_id

            Presence.update_element(
              presence_mod,
              sock,
              topic,
              user_id,
              element_id,
              type,
              client_id
            )

            {:halt, assign(sock, :collab_active_element, element_id)}

          {:error, _reason} ->
            {:halt, sock}
        end

      "live_collab:element_inactive", params, sock ->
        client_id = params["client_id"] || sock.assigns[:collab_client_id]
        topic = sock.assigns.collab_topic
        user_id = Map.get(user, :id) || Map.get(user, "id") || client_id

        Presence.clear_element(presence_mod, sock, topic, user_id, client_id)

        {:halt, assign(sock, :collab_active_element, nil)}

      _other_event, _params, sock ->
        {:cont, sock}
    end)
  end

  defp attach_collab_info_hook(socket, _config, presence_mod, topic) do
    attach_hook(socket, :live_collab_info, :handle_info, fn
      %Phoenix.Socket.Broadcast{event: "presence_diff", topic: ^topic}, sock ->
        {:halt, handle_presence_sync(sock, presence_mod, topic)}

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

  defp raise_missing_presence! do
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

      def handle_event("live_collab:field_focus", %{"field" => field} = params, socket) do
        client_id = params["client_id"] || socket.assigns[:collab_client_id]
        config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
        presence_mod = config.presence
        topic = socket.assigns.collab_topic
        user = socket.assigns[:current_user] || %{}
        user_id = Map.get(user, :id) || client_id

        case LiveCollab.Field.validate_field_id(field, config.max_field_id_length) do
          {:ok, field_id} ->
            LiveCollab.Presence.update_field(
              presence_mod,
              socket,
              topic,
              user_id,
              field_id,
              client_id
            )

            {:noreply, assign(socket, :collab_editing_field, field_id)}

          {:error, _} ->
            {:noreply, socket}
        end
      end

      def handle_event("live_collab:field_blur", params, socket) do
        client_id = params["client_id"] || socket.assigns[:collab_client_id]
        config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
        presence_mod = config.presence
        topic = socket.assigns.collab_topic
        user = socket.assigns[:current_user] || %{}
        user_id = Map.get(user, :id) || client_id

        LiveCollab.Presence.clear_field(presence_mod, socket, topic, user_id, client_id)

        {:noreply, assign(socket, :collab_editing_field, nil)}
      end

      def handle_event("live_collab:element_active", %{"element" => element} = params, socket) do
        client_id = params["client_id"] || socket.assigns[:collab_client_id]
        config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
        presence_mod = config.presence
        topic = socket.assigns.collab_topic
        user = socket.assigns[:current_user] || %{}
        user_id = Map.get(user, :id) || client_id

        case LiveCollab.Element.validate_element_id(element, config.max_field_id_length) do
          {:ok, element_id} ->
            type = LiveCollab.Element.normalize_activity_type(params["type"])

            LiveCollab.Presence.update_element(
              presence_mod,
              socket,
              topic,
              user_id,
              element_id,
              type,
              client_id
            )

            {:noreply, assign(socket, :collab_active_element, element_id)}

          {:error, _} ->
            {:noreply, socket}
        end
      end

      def handle_event("live_collab:element_inactive", params, socket) do
        client_id = params["client_id"] || socket.assigns[:collab_client_id]
        config = socket.assigns[:collab_config] || LiveCollab.Config.get(unquote(opts))
        presence_mod = config.presence
        topic = socket.assigns.collab_topic
        user = socket.assigns[:current_user] || %{}
        user_id = Map.get(user, :id) || client_id

        LiveCollab.Presence.clear_element(presence_mod, socket, topic, user_id, client_id)

        {:noreply, assign(socket, :collab_active_element, nil)}
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
    end
  end
end
