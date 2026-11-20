defmodule LiveCollab.LiveView do
  @moduledoc """
  LiveView lifecycle integration for LiveCollab.

  `track/4` (also available as `LiveCollab.track/4`) is the only call a LiveView
  needs. It tracks the process in `Phoenix.Presence`, subscribes to the
  collaboration topic and attaches two lifecycle hooks (`:handle_event` and
  `:handle_info`) that implement every `live_collab:*` event. Your own
  `handle_event/3` and `handle_info/2` callbacks keep working unchanged:
  LiveCollab only intercepts `live_collab:*` events and its own messages.

      def mount(%{"id" => id}, _session, socket) do
        {:ok, LiveCollab.track(socket, "order:\#{id}", socket.assigns.current_user)}
      end

  ## Assigns

  `track/4` sets the following assigns (also on the disconnected mount, with
  empty collaboration state):

    * `@collab_users` - collaborators, see `LiveCollab.Presence.extract_users/1`
    * `@collab_locks` - `%{field_id => lock_meta}`, see `LiveCollab.Field`
    * `@collab_activities` - `%{element_id => [activity]}`, see `LiveCollab.Element`
    * `@collab_client_id` - this LiveView's server-generated client id
    * `@collab_topic` - the collaboration topic
    * `@collab_editing_field` - the field this client currently claims, or `nil`
    * `@collab_active_element` - the element this client is active on, or `nil`
    * `@collab_spotlight_leader` - client id of the current presenter, or `nil`
    * `@collab_user_key`, `@collab_pubsub`, `@collab_config` - integration details

  Internal state (rate limiters, sync bookkeeping) lives in `socket.private`, so
  high-frequency events never mark assigns as changed and never trigger a render.

  ## Lifecycle

    * **Disconnected mount** - assigns only; nothing is tracked or subscribed.
    * **Connected mount** - tracked and subscribed. Presence entries and PubSub
      subscriptions are owned by the LiveView process and are removed
      automatically when it exits, so no `terminate/2` callback is required.
    * **Re-tracking** - calling `track/4` again with the same resource is a no-op;
      with a different resource (e.g. from `handle_params/3` after a
      `push_patch`) the previous topic is untracked first.
    * **`untrack/2`** - removes Presence and unsubscribes. The hooks stay
      attached and absorb late `live_collab:*` events from client hooks and
      messages for the old topic that were already in flight, so neither can
      reach (and crash) your `handle_event/3` or `handle_info/2`.

  A LiveView process can track one resource at a time.

  ## Client events

  All `live_collab:*` events are halted here, including unknown or malformed
  ones, so a client can never route them into your callbacks. Every value is
  validated; client-supplied identity (`client_id`, user ids) is ignored.

  | Event | Rate-limit bucket | Effect |
  | :--- | :--- | :--- |
  | `field_focus` / `field_blur` | presence (focus only) | claim / release a field lock |
  | `element_active` / `element_inactive` | presence (active only) | element/row activity |
  | `cursor_move` / `cursor_left` | telemetry | relay cursor to peers |
  | `viewport_move` | telemetry | relay scroll position to peers |
  | `selection_move` / `selection_clear` | telemetry | relay selection box to peers |
  | `spotlight_lead` / `spotlight_stop` | telemetry | presenter mode (authorized) |
  | `status` (`"active"` / `"away"`) | presence | away/idle status shown on avatars |

  Releases (`field_blur`, `element_inactive`) are never rate limited, but they
  only write to Presence when there is something to release. A blur that names a
  field other than the one currently claimed is ignored, so a delayed blur from a
  previous input cannot release the lock of the input that now has focus.

  ## Server-to-client events

    * `live_collab:init` - `%{client_id: id}`
    * `live_collab:lock_lost` (and `live_collab:lock_lost:<field>`) - `%{field, locked_by}`
    * `live_collab:cursor_moved`, `live_collab:cursor_left`
    * `live_collab:viewport_moved`, `live_collab:spotlight_status`,
      `live_collab:spotlight_unauthorized`
    * `live_collab:selection_moved`, `live_collab:selection_cleared`
    * `live_collab:peers_left` - `%{client_ids: [id]}` when collaborators leave,
      so clients can remove their cursors and selections immediately.
  """

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [connected?: 1, attach_hook: 4, push_event: 3, put_private: 3]

  alias LiveCollab.Config
  alias LiveCollab.Cursor
  alias LiveCollab.Element
  alias LiveCollab.Field
  alias LiveCollab.Presence
  alias LiveCollab.RateLimiter
  alias LiveCollab.Telemetry
  alias LiveCollab.Validation
  alias LiveCollab.Viewport

  @private_key :live_collab
  @event_hook :live_collab_events
  @info_hook :live_collab_info

  defmodule Session do
    @moduledoc false
    # Per-LiveView collaboration state kept in socket.private.
    @enforce_keys [:topic, :pubsub, :presence, :client_id, :user_key, :identity, :user, :config]
    defstruct [
      :topic,
      :pubsub,
      :presence,
      :client_id,
      :user_key,
      :identity,
      :user,
      :config,
      :telemetry_limiter,
      :presence_limiter,
      active_type: nil,
      status: :active,
      sync_pending: false,
      last_sync_at: nil,
      # Local replica of this topic's Presence entries, kept current by applying
      # presence_diff payloads (see apply_presence_diff/2).
      entries: %{},
      coalesced_diffs: 0,
      peer_clients: MapSet.new(),
      denied_streak: %{telemetry: 0, presence: 0}
    ]
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Tracks collaborative presence on `resource` for `user`.

  `user` is any map with `:id`, `:name` and optionally `:avatar_url` and `:color`
  (atom or string keys). See `LiveCollab.Presence.identity/2` for how missing or
  unsafe values are handled.

  ## Options

  Any `LiveCollab.Config` key, plus:

    * `:client_id` - override the generated client id (useful in tests). It is
      server-side only; the browser can never choose it.

  Raises `ArgumentError` when no Presence module is configured or when the
  configuration is invalid.
  """
  @spec track(Phoenix.LiveView.Socket.t(), term(), map(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def track(socket, resource, user, opts \\ []) when is_map(user) and is_list(opts) do
    config = Config.get(opts)
    presence_mod = config.presence || raise_missing_presence!()
    topic = Config.topic(config, resource)

    case session(socket) do
      %Session{topic: ^topic} -> socket
      %Session{} -> socket |> untrack() |> do_track(config, presence_mod, topic, user, opts)
      nil -> do_track(socket, config, presence_mod, topic, user, opts)
    end
  end

  @doc """
  Stops collaborating: untracks Presence, unsubscribes from the topic and resets
  the collaboration assigns. Late `live_collab:*` events from the browser and
  in-flight messages for the old topic are absorbed (and ignored).

  Safe to call on a socket that is not tracked.
  """
  @spec untrack(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def untrack(socket, _opts \\ []) do
    socket =
      case session(socket) do
        %Session{} = session ->
          Phoenix.PubSub.unsubscribe(session.pubsub, session.topic)
          Presence.untrack(session.presence, self(), session.topic, session.user_key)

          Telemetry.execute(
            [:session, :stop],
            %{system_time: System.system_time()},
            meta(session)
          )

          # Hooks stay attached for the life of the process: client hooks still
          # in the DOM may keep sending live_collab:* events, and messages for
          # this topic may already be in the mailbox. Both must be absorbed here
          # rather than reach the application's handle_event/3 / handle_info/2.
          put_private(socket, @private_key, nil)

        nil ->
          socket
      end

    socket
    |> assign(:collab_topic, nil)
    |> assign(:collab_user_key, nil)
    |> assign(:collab_users, [])
    |> assign(:collab_locks, %{})
    |> assign(:collab_activities, %{})
    |> assign(:collab_editing_field, nil)
    |> assign(:collab_active_element, nil)
    |> assign(:collab_spotlight_leader, nil)
  end

  @doc """
  Recomputes `@collab_users`, `@collab_locks` and `@collab_activities` from the
  current Presence state and notifies the client if it lost a lock.

  LiveCollab calls this automatically (coalescing bursts of `presence_diff`
  messages into a single recomputation); it is public for advanced integrations
  and tests.
  """
  @spec handle_presence_sync(Phoenix.LiveView.Socket.t(), module(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_presence_sync(socket, presence_module, topic) do
    entries = presence_module.list(topic)

    socket =
      case session(socket) do
        %Session{topic: ^topic} = session -> put_session(socket, %{session | entries: entries})
        _ -> socket
      end

    rebuild(socket, entries)
  end

  # Derives users / locks / activities from Presence entries. O(room size).
  defp rebuild(socket, entries) do
    started = System.monotonic_time()
    config = socket.assigns[:collab_config] || Config.get()
    users = Presence.extract_users(entries)
    locks = Field.extract_locks(entries, clock_skew_tolerance_ms: config.clock_skew_tolerance_ms)
    activities = Element.extract_activities(entries)

    socket =
      socket
      |> check_lock_lost(locks)
      |> assign(:collab_users, users)
      |> assign(:collab_locks, locks)
      |> assign(:collab_activities, activities)

    case session(socket) do
      %Session{} = session ->
        clients = client_ids(entries)
        {socket, session} = notify_departures(socket, session, clients)

        Telemetry.execute(
          [:presence, :sync],
          %{
            duration: System.monotonic_time() - started,
            users: length(users),
            metas: MapSet.size(clients),
            coalesced_diffs: session.coalesced_diffs
          },
          meta(session)
        )

        put_session(socket, %{
          session
          | peer_clients: clients,
            coalesced_diffs: 0,
            last_sync_at: System.monotonic_time(:millisecond)
        })

      nil ->
        socket
    end
  end

  # ============================================================================
  # Authorization
  # ============================================================================

  @doc """
  Returns whether this socket/user may lead a spotlight presentation.

  Presenting is allowed by default. It is denied when the socket is not tracked,
  when `@collab_can_present?` or `@can_present?` is `false`, when the user map
  has `can_present?: false` (or `"can_present" => false`), or when its role is
  `viewer` or `observer` (atom or string, `:role` or `"role"`).
  """
  @spec authorized_spotlight_leader?(Phoenix.LiveView.Socket.t(), map()) :: boolean()
  def authorized_spotlight_leader?(socket, user) do
    cond do
      is_nil(socket.assigns[:collab_client_id]) -> false
      Map.get(socket.assigns, :collab_can_present?) == false -> false
      Map.get(socket.assigns, :can_present?) == false -> false
      Map.get(user, :can_present?) == false -> false
      Map.get(user, "can_present") == false -> false
      Map.get(user, :role) in [:viewer, "viewer", :observer, "observer"] -> false
      Map.get(user, "role") in ["viewer", "observer"] -> false
      true -> true
    end
  end

  @doc """
  Returns whether `client_id` may stop the current spotlight: the current leader
  may always stop it; anyone else needs `authorized_spotlight_leader?/2`.
  """
  @spec can_stop_spotlight?(Phoenix.LiveView.Socket.t(), map(), String.t() | nil) :: boolean()
  def can_stop_spotlight?(socket, user, client_id) do
    current_leader = socket.assigns[:collab_spotlight_leader]

    cond do
      is_nil(client_id) -> false
      current_leader == client_id -> true
      authorized_spotlight_leader?(socket, user) -> true
      true -> false
    end
  end

  # ============================================================================
  # Tracking
  # ============================================================================

  defp do_track(socket, config, presence_mod, topic, user, opts) do
    client_id = Keyword.get_lazy(opts, :client_id, &generate_client_id/0)
    identity = Presence.identity(user, client_id)

    socket =
      socket
      |> assign(:collab_topic, topic)
      |> assign(:collab_client_id, client_id)
      |> assign(:collab_user_key, identity.key)
      |> assign(:collab_config, config)
      |> assign(:collab_users, [])
      |> assign(:collab_locks, %{})
      |> assign(:collab_activities, %{})
      |> assign(:collab_editing_field, nil)
      |> assign(:collab_active_element, nil)
      |> assign(:collab_spotlight_leader, nil)

    if connected?(socket) do
      pubsub = Config.pubsub_server!(config)
      :ok = Phoenix.PubSub.subscribe(pubsub, topic)

      case Presence.track(presence_mod, self(), topic, user, client_id) do
        {:ok, _ref} ->
          :ok

        {:error, reason} ->
          Phoenix.PubSub.unsubscribe(pubsub, topic)
          raise "LiveCollab could not track #{inspect(topic)} in Presence: #{inspect(reason)}"
      end

      session = %Session{
        topic: topic,
        pubsub: pubsub,
        presence: presence_mod,
        client_id: client_id,
        user_key: identity.key,
        identity: identity,
        user: user,
        config: config,
        telemetry_limiter:
          RateLimiter.new(
            rate: config.telemetry_rate_per_sec,
            burst: config.telemetry_burst_limit
          ),
        presence_limiter:
          RateLimiter.new(rate: config.presence_rate_per_sec, burst: config.presence_burst_limit)
      }

      Telemetry.execute([:session, :start], %{system_time: System.system_time()}, meta(session))

      socket
      |> assign(:collab_pubsub, pubsub)
      |> put_private(@private_key, session)
      |> ensure_hooks(topic)
      |> push_event("live_collab:init", %{client_id: client_id})
      |> handle_presence_sync(presence_mod, topic)
    else
      assign(socket, :collab_pubsub, config.pubsub)
    end
  end

  # ============================================================================
  # handle_event hook
  # ============================================================================

  @doc false
  def __handle_event__("live_collab:" <> event, params, socket) do
    case session(socket) do
      %Session{} = session ->
        params = if is_map(params), do: params, else: %{}
        {:halt, handle_client_event(event, params, socket, session)}

      nil ->
        {:halt, socket}
    end
  end

  def __handle_event__(_event, _params, socket), do: {:cont, socket}

  # --- Field locks ------------------------------------------------------------

  defp handle_client_event("field_focus", %{"field" => raw} = params, socket, session) do
    with_validated(socket, session, "field_focus", fn ->
      Field.validate_field_id(raw, session.config.max_field_id_length)
    end)
    |> case do
      {:ok, field} -> claim_field(socket, session, field, params)
      {:rejected, socket} -> socket
    end
  end

  defp handle_client_event("field_blur", params, socket, session) do
    current = socket.assigns[:collab_editing_field]

    case release_target(
           params["field"],
           current,
           &Field.validate_field_id(&1, session.config.max_field_id_length)
         ) do
      :release ->
        Presence.clear_field(
          session.presence,
          self(),
          session.topic,
          session.user_key,
          session.client_id
        )

        Telemetry.execute([:lock, :released], %{}, Map.put(meta(session), :field, current))
        assign(socket, :collab_editing_field, nil)

      :ignore ->
        socket

      {:invalid, reason} ->
        reject(socket, session, "field_blur", reason)
    end
  end

  # --- Element activity -------------------------------------------------------

  defp handle_client_event("element_active", %{"element" => raw} = params, socket, session) do
    with_validated(socket, session, "element_active", fn ->
      Element.validate_element_id(raw, session.config.max_field_id_length)
    end)
    |> case do
      {:ok, element} ->
        activate_element(
          socket,
          session,
          element,
          Element.normalize_activity_type(params["type"])
        )

      {:rejected, socket} ->
        socket
    end
  end

  defp handle_client_event("element_inactive", params, socket, session) do
    current = socket.assigns[:collab_active_element]

    case release_target(
           params["element"],
           current,
           &Element.validate_element_id(&1, session.config.max_field_id_length)
         ) do
      :release ->
        Presence.clear_element(
          session.presence,
          self(),
          session.topic,
          session.user_key,
          session.client_id
        )

        socket
        |> put_session(%{session | active_type: nil})
        |> assign(:collab_active_element, nil)

      :ignore ->
        socket

      {:invalid, reason} ->
        reject(socket, session, "element_inactive", reason)
    end
  end

  # --- Ephemeral telemetry (cursor / viewport / selection) -------------------

  defp handle_client_event("cursor_move", %{"x" => x, "y" => y} = params, socket, session) do
    rate_limited(socket, session, :telemetry, "cursor_move", fn socket, session ->
      with {:ok, nx, ny} <- Cursor.validate_coordinates(x, y),
           {:ok, container_id} <- container_id(params, session) do
        payload = Cursor.build_payload(session.client_id, session.identity, nx, ny, container_id)
        broadcast(session, {:collab_cursor_moved, session.topic, payload})
        socket
      else
        {:error, reason} -> reject(socket, session, "cursor_move", reason)
      end
    end)
  end

  defp handle_client_event("cursor_left", params, socket, session) do
    rate_limited(socket, session, :telemetry, "cursor_left", fn socket, session ->
      case container_id(params, session) do
        {:ok, container_id} ->
          broadcast(
            session,
            {:collab_cursor_left, session.topic,
             %{client_id: session.client_id, container_id: container_id}}
          )

          socket

        {:error, reason} ->
          reject(socket, session, "cursor_left", reason)
      end
    end)
  end

  defp handle_client_event(
         "viewport_move",
         %{"scroll_x" => sx, "scroll_y" => sy} = params,
         socket,
         session
       ) do
    rate_limited(socket, session, :telemetry, "viewport_move", fn socket, session ->
      max_len = session.config.max_field_id_length

      with {:ok, nsx, nsy, nzoom} <- Viewport.validate_viewport(sx, sy, params["zoom"] || 1.0),
           {:ok, container_id} <- container_id(params, session),
           {:ok, anchor} <- Validation.optional_identifier(params["anchor_element_id"], max_len) do
        payload =
          Viewport.build_viewport_payload(session.client_id, session.identity, nsx, nsy,
            zoom: nzoom,
            container_id: container_id,
            anchor_element_id: anchor
          )

        broadcast(session, {:collab_viewport_moved, session.topic, payload})
        socket
      else
        {:error, reason} -> reject(socket, session, "viewport_move", reason)
      end
    end)
  end

  defp handle_client_event(
         "selection_move",
         %{"x" => x, "y" => y, "width" => w, "height" => h} = params,
         socket,
         session
       ) do
    rate_limited(socket, session, :telemetry, "selection_move", fn socket, session ->
      with {:ok, nx, ny, nw, nh} <- Viewport.validate_selection(x, y, w, h),
           {:ok, container_id} <- container_id(params, session) do
        payload =
          Viewport.build_selection_payload(session.client_id, session.identity, nx, ny, nw, nh,
            container_id: container_id,
            selected_ids: params["selected_ids"] || []
          )

        broadcast(session, {:collab_selection_moved, session.topic, payload})
        socket
      else
        {:error, reason} -> reject(socket, session, "selection_move", reason)
      end
    end)
  end

  defp handle_client_event("selection_clear", params, socket, session) do
    rate_limited(socket, session, :telemetry, "selection_clear", fn socket, session ->
      case container_id(params, session) do
        {:ok, container_id} ->
          broadcast(
            session,
            {:collab_selection_cleared, session.topic,
             %{client_id: session.client_id, container_id: container_id}}
          )

          socket

        {:error, reason} ->
          reject(socket, session, "selection_clear", reason)
      end
    end)
  end

  # --- Spotlight ----------------------------------------------------------------

  defp handle_client_event("spotlight_lead", _params, socket, session) do
    rate_limited(socket, session, :telemetry, "spotlight_lead", fn socket, session ->
      if authorized_spotlight_leader?(socket, session.user) do
        broadcast(
          session,
          {:collab_spotlight_status, session.topic,
           %{
             client_id: session.client_id,
             user_id: session.identity.id,
             user_name: session.identity.name,
             user_color: session.identity.color,
             active: true
           }}
        )

        Telemetry.execute([:spotlight, :started], %{}, meta(session))
        assign(socket, :collab_spotlight_leader, session.client_id)
      else
        Telemetry.execute(
          [:spotlight, :unauthorized],
          %{},
          Map.put(meta(session), :action, :lead)
        )

        push_event(socket, "live_collab:spotlight_unauthorized", %{reason: "unauthorized"})
      end
    end)
  end

  defp handle_client_event("spotlight_stop", _params, socket, session) do
    rate_limited(socket, session, :telemetry, "spotlight_stop", fn socket, session ->
      cond do
        is_nil(socket.assigns[:collab_spotlight_leader]) ->
          socket

        can_stop_spotlight?(socket, session.user, session.client_id) ->
          leader = socket.assigns[:collab_spotlight_leader]

          broadcast(
            session,
            {:collab_spotlight_status, session.topic, %{client_id: leader, active: false}}
          )

          Telemetry.execute([:spotlight, :stopped], %{}, meta(session))
          assign(socket, :collab_spotlight_leader, nil)

        true ->
          Telemetry.execute(
            [:spotlight, :unauthorized],
            %{},
            Map.put(meta(session), :action, :stop)
          )

          push_event(socket, "live_collab:spotlight_unauthorized", %{reason: "unauthorized"})
      end
    end)
  end

  # --- Away / idle status -------------------------------------------------------

  defp handle_client_event("status", %{"status" => raw}, socket, session) do
    case parse_status(raw) do
      {:ok, status} when status == session.status ->
        socket

      {:ok, status} ->
        rate_limited(socket, session, :presence, "status", fn socket, session ->
          Presence.update_status(
            session.presence,
            self(),
            session.topic,
            session.user_key,
            status
          )

          Telemetry.execute([:status, :changed], %{}, Map.put(meta(session), :status, status))
          put_session(socket, %{session | status: status})
        end)

      :error ->
        reject(socket, session, "status", :invalid_status)
    end
  end

  # Known event with missing/ill-typed params, or an unknown live_collab:* event.
  defp handle_client_event(event, _params, socket, session) do
    reason = if event in known_events(), do: :invalid_params, else: :unknown_event
    reject(socket, session, event, reason)
  end

  defp known_events do
    ~w(field_focus field_blur element_active element_inactive cursor_move cursor_left
       viewport_move selection_move selection_clear spotlight_lead spotlight_stop status)
  end

  defp parse_status("active"), do: {:ok, :active}
  defp parse_status("away"), do: {:ok, :away}
  defp parse_status(_), do: :error

  # ============================================================================
  # handle_info hook
  # ============================================================================

  @doc false
  def __handle_info__(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic, payload: diff},
        socket
      ) do
    case session(socket) do
      %Session{topic: ^topic, sync_pending: true} = session ->
        session = %{
          session
          | entries: apply_presence_diff(session.entries, diff),
            coalesced_diffs: session.coalesced_diffs + 1
        }

        {:halt, put_session(socket, session)}

      %Session{topic: ^topic} = session ->
        # Leading-edge throttle: after a quiet period the rebuild is scheduled
        # immediately (as a message, so diffs already queued behind this one are
        # folded in); during a burst it is deferred until
        # presence_sync_interval_ms after the previous rebuild. Each rebuild is
        # O(room size), so this bounds per-LiveView cost under join/focus storms.
        schedule_sync(session)

        session = %{
          session
          | entries: apply_presence_diff(session.entries, diff),
            sync_pending: true
        }

        {:halt, put_session(socket, session)}

      _ ->
        absorb_if_owned(socket, topic)
    end
  end

  def __handle_info__({:live_collab_sync, topic}, socket) do
    case session(socket) do
      %Session{topic: ^topic} = session ->
        socket = put_session(socket, %{session | sync_pending: false})
        {:halt, rebuild(socket, session.entries)}

      _ ->
        {:halt, socket}
    end
  end

  def __handle_info__({kind, topic, payload}, socket)
      when kind in [
             :collab_cursor_moved,
             :collab_cursor_left,
             :collab_viewport_moved,
             :collab_selection_moved,
             :collab_selection_cleared,
             :collab_spotlight_status
           ] do
    case session(socket) do
      %Session{topic: ^topic} = session when is_map(payload) ->
        {:halt, relay(kind, payload, socket, session)}

      %Session{topic: ^topic} ->
        {:halt, socket}

      _ ->
        absorb_if_owned(socket, topic)
    end
  end

  def __handle_info__(_msg, socket), do: {:cont, socket}

  # A message for a topic this process tracked earlier (before untrack/2 or a
  # re-track) can still be in flight after unsubscribing. It belongs to
  # LiveCollab and must not reach the application's handle_info/2. Messages for
  # topics LiveCollab never owned are passed through untouched.
  defp absorb_if_owned(socket, topic) do
    if MapSet.member?(owned_topics(socket), topic), do: {:halt, socket}, else: {:cont, socket}
  end

  defp owned_topics(socket), do: socket.private[:live_collab_topics] || MapSet.new()

  # The sender never receives its own broadcast (broadcast_from/4), so a spotlight
  # status always comes from someone else — including "your presentation was
  # stopped by a co-presenter", which carries the leader's own client_id.
  defp relay(:collab_spotlight_status, payload, socket, _session) do
    leader = if payload[:active], do: payload[:client_id], else: nil

    socket
    |> assign(:collab_spotlight_leader, leader)
    |> push_event("live_collab:spotlight_status", payload)
  end

  defp relay(kind, payload, socket, session) do
    if payload[:client_id] == session.client_id do
      socket
    else
      push_event(socket, client_event_name(kind), payload)
    end
  end

  defp client_event_name(:collab_cursor_moved), do: "live_collab:cursor_moved"
  defp client_event_name(:collab_cursor_left), do: "live_collab:cursor_left"
  defp client_event_name(:collab_viewport_moved), do: "live_collab:viewport_moved"
  defp client_event_name(:collab_selection_moved), do: "live_collab:selection_moved"
  defp client_event_name(:collab_selection_cleared), do: "live_collab:selection_cleared"

  # ============================================================================
  # Helpers
  # ============================================================================

  defp claim_field(socket, session, field, _params) do
    locks = socket.assigns[:collab_locks] || %{}

    cond do
      socket.assigns[:collab_editing_field] == field ->
        socket

      Field.locked_by_other?(locks, field, session.client_id) ->
        holder = Field.current_holder(locks, field)

        Telemetry.execute(
          [:lock, :denied],
          %{},
          meta(session)
          |> Map.put(:field, field)
          |> Map.put(:holder_client_id, holder[:client_id])
        )

        push_lock_lost(socket, field, holder[:user_name])

      true ->
        rate_limited(socket, session, :presence, "field_focus", fn socket, session ->
          Presence.update_field(
            session.presence,
            self(),
            session.topic,
            session.user_key,
            field,
            session.client_id
          )

          Telemetry.execute([:lock, :claimed], %{}, Map.put(meta(session), :field, field))
          assign(socket, :collab_editing_field, field)
        end)
    end
  end

  defp activate_element(socket, session, element, type) do
    if socket.assigns[:collab_active_element] == element and session.active_type == type do
      socket
    else
      rate_limited(socket, session, :presence, "element_active", fn socket, session ->
        Presence.update_element(
          session.presence,
          self(),
          session.topic,
          session.user_key,
          element,
          type,
          session.client_id
        )

        socket
        |> put_session(%{session | active_type: type})
        |> assign(:collab_active_element, element)
      end)
    end
  end

  defp check_lock_lost(socket, locks) do
    client_id = socket.assigns[:collab_client_id]
    field = socket.assigns[:collab_editing_field]

    if is_nil(field) or is_nil(client_id) do
      socket
    else
      check_holder(socket, field, client_id, Map.get(locks, field))
    end
  end

  defp check_holder(socket, _field, client_id, %{client_id: client_id}), do: socket
  defp check_holder(socket, field, _client_id, %{} = winner), do: lose_lock(socket, field, winner)
  # Our claim is no longer in Presence (e.g. cleared elsewhere): stop editing.
  defp check_holder(socket, _field, _client_id, nil),
    do: assign(socket, :collab_editing_field, nil)

  defp lose_lock(socket, field, winner) do
    if session = session(socket) do
      Telemetry.execute(
        [:lock, :lost],
        %{},
        meta(session)
        |> Map.put(:field, field)
        |> Map.put(:winner_client_id, winner[:client_id])
      )
    end

    socket
    |> assign(:collab_editing_field, nil)
    |> push_lock_lost(field, winner[:user_name])
  end

  defp push_lock_lost(socket, field, locked_by) do
    payload = %{field: field, locked_by: locked_by}

    socket
    |> push_event("live_collab:lock_lost", payload)
    |> push_event("live_collab:lock_lost:#{field}", payload)
  end

  defp notify_departures(socket, session, clients) do
    departed =
      session.peer_clients |> MapSet.difference(clients) |> MapSet.delete(session.client_id)

    if MapSet.size(departed) == 0 do
      {socket, session}
    else
      socket =
        push_event(socket, "live_collab:peers_left", %{client_ids: MapSet.to_list(departed)})

      leader = socket.assigns[:collab_spotlight_leader]

      socket =
        if leader && MapSet.member?(departed, leader) do
          socket
          |> assign(:collab_spotlight_leader, nil)
          |> push_event("live_collab:spotlight_status", %{client_id: leader, active: false})
        else
          socket
        end

      {socket, session}
    end
  end

  defp schedule_sync(%Session{} = session) do
    message = {:live_collab_sync, session.topic}
    interval = session.config.presence_sync_interval_ms
    elapsed = System.monotonic_time(:millisecond) - (session.last_sync_at || 0)

    if is_nil(session.last_sync_at) or elapsed >= interval do
      send(self(), message)
    else
      Process.send_after(self(), message, interval - elapsed)
    end
  end

  # Applies a Phoenix.Presence diff to the local replica, the same way the
  # Phoenix JS client does (joins, then leaves; metas identified by :phx_ref).
  #
  # Rebuilding from local state instead of calling Presence.list/1 matters at
  # scale: list/1 is a GenServer.call into a Tracker shard that returns (copies)
  # the shard's state, so hundreds of LiveViews listing after every change turn
  # one shard into a global bottleneck. Diffs arrive in order from the local
  # Presence process, and re-applying a change already contained in the initial
  # list/1 is idempotent, so the replica converges to the Presence state.
  @doc false
  def apply_presence_diff(entries, %{joins: joins, leaves: leaves})
      when is_map(joins) and is_map(leaves) do
    entries
    |> apply_joins(joins)
    |> apply_leaves(leaves)
  end

  def apply_presence_diff(entries, _malformed), do: entries

  defp apply_joins(entries, joins) do
    Enum.reduce(joins, entries, fn
      {key, %{metas: joined}}, acc when is_list(joined) ->
        Map.update(acc, key, %{metas: joined}, fn %{metas: metas} = entry ->
          refs = MapSet.new(metas, &meta_ref/1)
          %{entry | metas: metas ++ Enum.reject(joined, &MapSet.member?(refs, meta_ref(&1)))}
        end)

      _other, acc ->
        acc
    end)
  end

  defp apply_leaves(entries, leaves) do
    Enum.reduce(leaves, entries, fn
      {key, %{metas: left}}, acc when is_list(left) ->
        remove_metas(acc, key, MapSet.new(left, &meta_ref/1))

      _other, acc ->
        acc
    end)
  end

  defp remove_metas(entries, key, refs) do
    case entries do
      %{^key => %{metas: metas} = entry} ->
        case Enum.reject(metas, &MapSet.member?(refs, meta_ref(&1))) do
          [] -> Map.delete(entries, key)
          remaining -> Map.put(entries, key, %{entry | metas: remaining})
        end

      _ ->
        entries
    end
  end

  defp meta_ref(meta) when is_map(meta), do: Map.get(meta, :phx_ref)
  defp meta_ref(_), do: nil

  defp client_ids(entries) do
    for {_key, %{metas: metas}} <- entries,
        %{client_id: client_id} <- metas,
        into: MapSet.new(),
        do: client_id
  end

  # Release semantics shared by field_blur and element_inactive:
  # nothing held -> ignore; no target named -> release; named target must match.
  defp release_target(_raw, nil, _validate), do: :ignore
  defp release_target(nil, _current, _validate), do: :release

  defp release_target(raw, current, validate) do
    case validate.(raw) do
      {:ok, ^current} -> :release
      {:ok, _other} -> :ignore
      {:error, reason} -> {:invalid, reason}
    end
  end

  defp with_validated(socket, session, event, validate) do
    case validate.() do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:rejected, reject(socket, session, event, reason)}
    end
  end

  defp container_id(params, session) do
    Validation.optional_identifier(params["container_id"], session.config.max_field_id_length)
  end

  defp rate_limited(socket, session, bucket, event, fun) do
    limiter_key = limiter_key(bucket)

    case RateLimiter.check(Map.fetch!(session, limiter_key)) do
      {:allow, limiter} ->
        session =
          session
          |> Map.put(limiter_key, limiter)
          |> Map.update!(:denied_streak, &Map.put(&1, bucket, 0))

        fun.(put_session(socket, session), session)

      {:deny, limiter} ->
        streak = session.denied_streak[bucket] + 1

        session =
          session
          |> Map.put(limiter_key, limiter)
          |> Map.update!(:denied_streak, &Map.put(&1, bucket, streak))

        Telemetry.execute(
          [:event, :rate_limited],
          %{count: 1},
          meta(session) |> Map.merge(%{event: event, bucket: bucket, consecutive: streak})
        )

        put_session(socket, session)
    end
  end

  defp limiter_key(:telemetry), do: :telemetry_limiter
  defp limiter_key(:presence), do: :presence_limiter

  defp reject(socket, session, event, reason) do
    Telemetry.execute(
      [:event, :rejected],
      %{count: 1},
      Map.merge(meta(session), %{event: event, reason: reason})
    )

    socket
  end

  defp broadcast(session, message) do
    Phoenix.PubSub.broadcast_from(session.pubsub, self(), session.topic, message)
  end

  defp meta(%Session{} = session) do
    %{topic: session.topic, client_id: session.client_id, user_key: session.user_key}
  end

  defp session(socket), do: socket.private[@private_key]

  # Hooks are attached once per process and never detached (see untrack/2).
  defp ensure_hooks(socket, topic) do
    socket =
      if socket.private[:live_collab_topics] do
        socket
      else
        socket
        |> attach_hook(@event_hook, :handle_event, &__MODULE__.__handle_event__/3)
        |> attach_hook(@info_hook, :handle_info, &__MODULE__.__handle_info__/2)
      end

    put_private(socket, :live_collab_topics, MapSet.put(owned_topics(socket), topic))
  end

  defp put_session(socket, %Session{} = session), do: put_private(socket, @private_key, session)

  defp generate_client_id do
    "cli_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  @spec raise_missing_presence!() :: no_return()
  defp raise_missing_presence! do
    raise ArgumentError, """
    LiveCollab requires a Phoenix.Presence module to be configured.

    Configure in config/config.exs:

        config :live_collab, presence: MyAppWeb.Presence

    or pass it as an option:

        LiveCollab.track(socket, resource, user, presence: MyAppWeb.Presence)
    """
  end

  @doc """
  Imports `LiveCollab.Components`.

  Earlier versions also injected `handle_event/3` and `handle_info/2` clauses.
  Those clauses were unreachable (the lifecycle hooks attached by `track/4`
  always handle the events first) and called a private function, so they were
  removed; `track/4` alone is sufficient.
  """
  defmacro __using__(_opts) do
    quote do
      import LiveCollab.Components
    end
  end
end
