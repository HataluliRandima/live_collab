defmodule LiveCollab do
  @moduledoc """
  # LiveCollab

  Multiplayer collaborative primitives for Phoenix LiveView applications.

  LiveCollab brings real-time collaborative features into Phoenix LiveView
  using Phoenix's built-in infrastructure:
  - `Phoenix.Presence` for durable collaborative state (presence, avatar stacks, field locking)
  - `Phoenix.PubSub` for ephemeral, high-frequency telemetry (cursors, viewports)
  - Zero external brokers, Redis, or SaaS dependencies.

  ## Quick Start

  ### 1. Configure Presence in your application

  In `config/config.exs`:

      config :live_collab,
        presence: MyAppWeb.Presence,
        pubsub: MyApp.PubSub

  ### 2. Track collaboration in your LiveView

      defmodule MyAppWeb.OrderLive do
        use MyAppWeb, :live_view

        def mount(%{"id" => id}, _session, socket) do
          user = socket.assigns.current_user

          socket =
            socket
            |> assign(:order, get_order!(id))
            |> LiveCollab.track("order:\#{id}", user)

          {:ok, socket}
        end
      end

  ### 3. Add UI components in your HEEx template

      <%!-- Collaborative Avatar Stack --%>
      <LiveCollab.Components.avatar_stack users={@collab_users} />

      <%!-- Collaborative Input with Editing Lock & Indicator --%>
      <div class="relative">
        <label>Customer Name</label>
        <input
          type="text"
          name="order[customer_name]"
          value={@order.customer_name}
          {LiveCollab.Components.collab_attrs("order.customer_name", @collab_locks, @collab_client_id)}
        />
        <LiveCollab.Components.field_indicator
          field="order.customer_name"
          locks={@collab_locks}
          current_client_id={@collab_client_id}
        />
      </div>

  ### 4. Wire client hooks in `app.js`

      import { LiveCollabHooks } from "live_collab"

      let liveSocket = new LiveSocket("/live", Socket, {
        params: {_csrf_token: csrfToken},
        hooks: { ...LiveCollabHooks }
      })
  """

  alias LiveCollab.Config
  alias LiveCollab.Field
  alias LiveCollab.LiveView, as: LV
  alias LiveCollab.Presence

  @doc """
  Tracks collaborative presence on a resource for the given socket and user.
  Automatically attaches LiveView lifecycle hooks for handling field focus/blur and presence diffs.
  """
  defdelegate track(socket, resource, user, opts \\ []), to: LV

  @doc """
  Untracks collaboration and unsubscribes from the collaboration topic.
  """
  defdelegate untrack(socket, opts \\ []), to: LV

  @doc """
  Checks if a field is currently locked.
  Accepts either a LiveView socket (with `@collab_locks` assigned) or directly a locks map.
  """
  @spec locked?(Phoenix.LiveView.Socket.t() | Field.locks_map(), String.t()) :: boolean()
  def locked?(%Phoenix.LiveView.Socket{assigns: %{collab_locks: locks}}, field_id) do
    Field.locked?(locks, field_id)
  end

  def locked?(locks, field_id) when is_map(locks) do
    Field.locked?(locks, field_id)
  end

  @doc """
  Checks if a field is locked by another collaborator.
  """
  @spec locked_by_other?(
          Phoenix.LiveView.Socket.t() | Field.locks_map(),
          String.t(),
          String.t() | nil
        ) :: boolean()
  def locked_by_other?(
        %Phoenix.LiveView.Socket{assigns: %{collab_locks: locks, collab_client_id: client_id}},
        field_id,
        _explicit_client_id
      ) do
    Field.locked_by_other?(locks, field_id, client_id)
  end

  def locked_by_other?(locks, field_id, client_id) when is_map(locks) do
    Field.locked_by_other?(locks, field_id, client_id)
  end

  @doc """
  Returns the collaborator metadata currently locking a field, or `nil` if free.
  """
  @spec current_holder(Phoenix.LiveView.Socket.t() | Field.locks_map(), String.t()) ::
          Field.lock_meta() | nil
  def current_holder(%Phoenix.LiveView.Socket{assigns: %{collab_locks: locks}}, field_id) do
    Field.current_holder(locks, field_id)
  end

  def current_holder(locks, field_id) when is_map(locks) do
    Field.current_holder(locks, field_id)
  end

  @doc """
  Generates a deterministic color string for a given user identifier.
  """
  defdelegate user_color(identifier), to: Presence, as: :deterministic_color

  @doc """
  Extracts 1-2 uppercase initials from a person's display name.
  """
  defdelegate user_initials(name), to: Presence, as: :initials

  @doc """
  Validates a field identifier sent from an untrusted client.
  """
  defdelegate validate_field_id(field_id, max_length \\ 255), to: Field

  @doc """
  Validates that a field is not locked during changeset processing (`phx-change` or `phx-submit`).
  """
  defdelegate validate_not_locked(changeset, field_name, locks, client_id, opts \\ []),
    to: Field
end
