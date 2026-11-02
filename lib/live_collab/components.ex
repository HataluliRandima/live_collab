defmodule LiveCollab.Components do
  @moduledoc """
  Functional HEEx components for LiveCollab.

  Designed to be accessible, zero-dependency, and easily styled using Tailwind CSS,
  custom CSS variables, or custom utility classes.
  """

  use Phoenix.Component
  alias LiveCollab.Element
  alias LiveCollab.Field
  alias LiveCollab.Presence

  @doc """
  Renders an accessible avatar stack for active collaborative users.

  ## Examples

      <.avatar_stack users={@collab_users} />

      <.avatar_stack
        users={@collab_users}
        max={3}
        size="lg"
        class="my-custom-stack"
      />

  ## Attributes

  - `users` (required): List of user structs/maps from `@collab_users`.
  - `max` (optional): Maximum avatars to render before collapsing to an overflow badge (default `4`).
  - `size` (optional): Size preset (`"xs"`, `"sm"`, `"md"`, `"lg"`), default `"md"`.
  - `class` (optional): Additional CSS classes for outer container.
  - `show_tabs_count` (optional): Whether to indicate multi-tab sessions with a small indicator (default `true`).
  """
  attr :users, :list, required: true, doc: "List of users from @collab_users"
  attr :max, :integer, default: 4, doc: "Maximum visible avatars before overflow indicator"
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :class, :string, default: nil, doc: "Optional CSS classes on wrapper"
  attr :show_tabs_count, :boolean, default: true, doc: "Show count badge if user has multiple tabs"

  slot :user_avatar, doc: "Custom avatar rendering slot for each user"
  slot :overflow_indicator, doc: "Custom overflow rendering slot"

  def avatar_stack(assigns) do
    total = length(assigns.users)
    visible = Enum.take(assigns.users, assigns.max)
    overflow = total - assigns.max

    assigns =
      assigns
      |> assign(:visible, visible)
      |> assign(:overflow, overflow)
      |> assign(:total, total)

    ~H"""
    <div
      role="group"
      aria-label="Active collaborators"
      class={["live-collab-avatar-stack inline-flex items-center -space-x-2 overflow-visible", @class]}
    >
      <%= for user <- @visible do %>
        <%= if @user_avatar != [] do %>
          <%= render_slot(@user_avatar, user) %>
        <% else %>
          <.avatar user={user} size={@size} show_tabs_count={@show_tabs_count} />
        <% end %>
      <% end %>

      <%= if @overflow > 0 do %>
        <%= if @overflow_indicator != [] do %>
          <%= render_slot(@overflow_indicator, @overflow) %>
        <% else %>
          <div
            role="status"
            title={"#{@overflow} more collaborators"}
            aria-label={"#{@overflow} more collaborators"}
            class={[
              "live-collab-overflow flex items-center justify-center font-semibold rounded-full ring-2 ring-white bg-gray-200 text-gray-700 text-xs shadow-sm",
              avatar_size_class(@size)
            ]}
          >
            +<%= @overflow %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders an individual avatar circle with image or initials fallback.
  """
  attr :user, :map, required: true
  attr :size, :string, default: "md"
  attr :show_tabs_count, :boolean, default: true

  def avatar(assigns) do
    tabs_count = Map.get(assigns.user, :tabs_count, 1)
    assigns = assign(assigns, :tabs_count, tabs_count)

    ~H"""
    <div
      class="relative group focus:outline-none"
      tabindex="0"
      aria-label={"Collaborator #{@user.name}"}
      title={"#{@user.name}#{if @tabs_count > 1, do: " (#{@tabs_count} tabs)", else: ""}"}
    >
      <%= if @user.avatar_url do %>
        <img
          src={@user.avatar_url}
          alt={@user.name}
          class={[
            "rounded-full ring-2 ring-white object-cover shadow-sm",
            avatar_size_class(@size)
          ]}
        />
      <% else %>
        <div
          class={[
            "rounded-full ring-2 ring-white text-white font-medium flex items-center justify-center shadow-sm select-none",
            avatar_size_class(@size)
          ]}
          style={"background-color: #{@user.color};"}
        >
          <%= @user.initials %>
        </div>
      <% end %>

      <%= if @show_tabs_count and @tabs_count > 1 do %>
        <span
          class="absolute -top-1 -right-1 bg-gray-900 text-white text-[9px] font-bold px-1 rounded-full border border-white"
          title={"#{@user.name} has #{@tabs_count} open tabs"}
        >
          <%= @tabs_count %>
        </span>
      <% end %>
      <%!-- Accessible hover tooltip --%>
      <span class="sr-only"><%= @user.name %></span>
    </div>
    """
  end

  @doc """
  Renders a visual indicator showing who is currently editing a field.

  ## Examples

      <.field_indicator
        field="customer.name"
        locks={@collab_locks}
        current_client_id={@collab_client_id}
      />
  """
  attr :field, :string, required: true, doc: "The field identifier"
  attr :locks, :map, required: true, doc: "The @collab_locks map"
  attr :current_client_id, :string, default: nil, doc: "The current tab client ID"
  attr :class, :string, default: nil

  def field_indicator(assigns) do
    lock = Map.get(assigns.locks, assigns.field)
    is_other = lock && lock.client_id != assigns.current_client_id

    assigns =
      assigns
      |> assign(:lock, lock)
      |> assign(:is_other, is_other)

    ~H"""
    <%= if @is_other do %>
      <div
        role="status"
        aria-live="polite"
        class={[
          "live-collab-field-indicator inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs font-medium text-white shadow-sm transition-all duration-150 animate-fadeIn",
          @class
        ]}
        style={"background-color: #{@lock.user_color || "#4F46E5"};"}
      >
        <span class="inline-block w-1.5 h-1.5 rounded-full bg-white animate-pulse"></span>
        <span class="truncate max-w-[140px]"><%= @lock.user_name %> is editing</span>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders an activity indicator for a table row showing active collaborators.

  ## Examples

      <.row_indicator
        element={"row:#{row.id}"}
        activities={@collab_activities}
        current_client_id={@collab_client_id}
      />
  """
  attr :element, :string, required: true, doc: "The element/row identifier, e.g. row:42"
  attr :activities, :map, required: true, doc: "The @collab_activities map"
  attr :current_client_id, :string, default: nil, doc: "The current tab client ID"
  attr :max, :integer, default: 3, doc: "Maximum visible avatars"
  attr :size, :string, default: "xs", values: ["xs", "sm", "md"]
  attr :class, :string, default: nil

  def row_indicator(assigns) do
    users = Element.active_users(assigns.activities, assigns.element)
    other_users = Enum.filter(users, &(&1.client_id != assigns.current_client_id))
    has_editing = Enum.any?(other_users, &(&1.type == :editing))

    assigns =
      assigns
      |> assign(:users, other_users)
      |> assign(:has_editing, has_editing)
      |> assign(:total, length(other_users))
      |> assign(:visible, Enum.take(other_users, assigns.max))
      |> assign(:overflow, length(other_users) - assigns.max)

    ~H"""
    <%= if @total > 0 do %>
      <div
        role="status"
        aria-live="polite"
        aria-label={"#{collaborator_summary(@users)} on this row"}
        class={["live-collab-row-indicator inline-flex items-center gap-1 overflow-visible", @class]}
      >
        <%!-- Stacked mini avatars --%>
        <div class="inline-flex items-center -space-x-1.5">
          <%= for user <- @visible do %>
            <div
              class="relative"
              title={"#{user.user_name} (#{user.type})"}
              aria-label={"#{user.user_name} (#{user.type})"}
            >
              <%= if user.user_avatar do %>
                <img
                  src={user.user_avatar}
                  alt={user.user_name}
                  class={["rounded-full ring-1 ring-white object-cover", avatar_size_class(@size)]}
                />
              <% else %>
                <div
                  class={[
                    "rounded-full ring-1 ring-white text-white font-medium flex items-center justify-center select-none",
                    avatar_size_class(@size)
                  ]}
                  style={"background-color: #{user.user_color};"}
                >
                  <%= Presence.initials(user.user_name) %>
                </div>
              <% end %>

              <%= if user.type == :editing do %>
                <span
                  class="absolute -bottom-0.5 -right-0.5 w-2 h-2 rounded-full bg-amber-400 ring-1 ring-white animate-pulse"
                  title="Editing"
                ></span>
              <% end %>
            </div>
          <% end %>

          <%= if @overflow > 0 do %>
            <div
              class={[
                "rounded-full ring-1 ring-white bg-gray-200 text-gray-700 font-semibold flex items-center justify-center",
                avatar_size_class(@size)
              ]}
              title={"#{@overflow} more viewing"}
            >
              +<%= @overflow %>
            </div>
          <% end %>
        </div>

        <%!-- Status text badge if someone is actively editing --%>
        <%= if @has_editing do %>
          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-amber-100 text-amber-800 animate-fadeIn">
            editing
          </span>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a customizable activity component for generic elements (cards, sections, blocks).
  """
  attr :element, :string, required: true
  attr :activities, :map, required: true
  attr :current_client_id, :string, default: nil
  attr :max, :integer, default: 4
  attr :size, :string, default: "sm"
  attr :class, :string, default: nil

  slot :user_badge
  slot :overflow_indicator

  def element_activity(assigns) do
    users = Element.active_users(assigns.activities, assigns.element)
    other_users = Enum.filter(users, &(&1.client_id != assigns.current_client_id))

    assigns =
      assigns
      |> assign(:users, other_users)
      |> assign(:total, length(other_users))
      |> assign(:visible, Enum.take(other_users, assigns.max))
      |> assign(:overflow, length(other_users) - assigns.max)

    ~H"""
    <%= if @total > 0 do %>
      <div
        role="group"
        aria-label={"Collaborators on #{@element}"}
        class={["live-collab-element-activity inline-flex items-center -space-x-1", @class]}
      >
        <%= for user <- @visible do %>
          <%= if @user_badge != [] do %>
            <%= render_slot(@user_badge, user) %>
          <% else %>
            <div
              class="relative"
              title={"#{user.user_name} (#{user.type})"}
              aria-label={"#{user.user_name} (#{user.type})"}
            >
              <div
                class={[
                  "rounded-full ring-1 ring-white text-white font-medium flex items-center justify-center select-none",
                  avatar_size_class(@size)
                ]}
                style={"background-color: #{user.user_color};"}
              >
                <%= Presence.initials(user.user_name) %>
              </div>
              <%= if user.type == :editing do %>
                <span class="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-amber-400 ring-1 ring-white"></span>
              <% end %>
            </div>
          <% end %>
        <% end %>

        <%= if @overflow > 0 do %>
          <%= if @overflow_indicator != [] do %>
            <%= render_slot(@overflow_indicator, @overflow) %>
          <% else %>
            <div
              class={[
                "rounded-full ring-1 ring-white bg-gray-200 text-gray-700 font-semibold flex items-center justify-center",
                avatar_size_class(@size)
              ]}
            >
              +<%= @overflow %>
            </div>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a high-performance collaborative cursor container layer.
  Attaches `phx-hook="LiveCollabCursor"` and prepares the hardware-accelerated SVG overlay.

  ## Examples

      <.cursor_layer container_id="board" class="w-full h-[600px] border rounded">
        <div>Your collaborative board content</div>
      </.cursor_layer>
  """
  attr :container_id, :string, default: "default", doc: "Identifier for container-relative coordinate mapping"
  attr :throttle, :integer, default: 30, doc: "Client throttle in milliseconds (~33 fps)"
  attr :deadband, :float, default: 0.0015, doc: "Normalized distance threshold to avoid jitter broadcasts"
  attr :class, :string, default: nil, doc: "CSS classes on the outer container"
  slot :inner_block, required: false

  def cursor_layer(assigns) do
    ~H"""
    <div
      class={["live-collab-cursor-container relative", @class]}
      {collab_cursor_attrs(@container_id, throttle: @throttle, deadband: @deadband)}
    >
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  Renders a container with collaborative viewport and scroll following.

  ## Examples

      <.viewport_container container_id="doc_viewport" class="overflow-y-auto h-screen">
        <div>Long document content</div>
      </.viewport_container>
  """
  attr :container_id, :string, default: "default"
  attr :presenter, :boolean, default: false, doc: "Whether this client is broadcasting scroll position as presenter"
  attr :following, :string, default: nil, doc: "Client ID of presenter to follow"
  attr :throttle, :integer, default: 40, doc: "Scroll broadcast throttle in milliseconds"
  attr :class, :string, default: nil
  slot :inner_block, required: false

  def viewport_container(assigns) do
    ~H"""
    <div
      class={["live-collab-viewport-container", @class]}
      {collab_viewport_attrs(@container_id,
        presenter: @presenter,
        following: @following,
        throttle: @throttle
      )}
    >
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  Renders an interactive pill showing who is currently presenting/leading, with
  a button to follow or unfollow.
  """
  attr :leader_name, :string, required: true
  attr :leader_client_id, :string, required: true
  attr :leader_color, :string, default: "#4F46E5"
  attr :is_following, :boolean, default: false
  attr :class, :string, default: nil

  def follow_pill(assigns) do
    ~H"""
    <div
      class={[
        "live-collab-follow-pill inline-flex items-center gap-2 px-3 py-1.5 rounded-full text-xs font-medium shadow-md transition-all select-none",
        if(@is_following, do: "bg-gray-900 text-white ring-2 ring-indigo-500", else: "bg-white text-gray-800 border border-gray-200"),
        @class
      ]}
    >
      <span class="w-2 h-2 rounded-full animate-pulse" style={"background-color: #{@leader_color};"}></span>
      <span><%= @leader_name %> is presenting</span>
      <button
        type="button"
        class={[
          "ml-1 px-2 py-0.5 rounded text-[11px] font-semibold transition-colors",
          if(@is_following, do: "bg-gray-800 text-gray-200 hover:bg-gray-700", else: "bg-indigo-600 text-white hover:bg-indigo-500")
        ]}
        onclick={"this.closest('.live-collab-viewport-container, body').dispatchEvent(new CustomEvent('#{if @is_following, do: "live_collab:stop_follow", else: "live_collab:start_follow"}', {bubbles: true, detail: {client_id: '#{@leader_client_id}'}}))"}
      >
        <%= if @is_following, do: "Stop Following", else: "Follow" %>
      </button>
    </div>
    """
  end

  @doc """
  Renders an overlay container that displays real-time multiplayer selection bounding boxes.
  """
  attr :container_id, :string, default: "default"
  attr :class, :string, default: nil
  slot :inner_block, required: false

  def selection_layer(assigns) do
    ~H"""
    <div
      class={["live-collab-selection-container relative", @class]}
      {collab_selection_attrs(@container_id)}
    >
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  Generates HTML tag attributes to attach the `LiveCollabCursor` hook to any
  existing container element (e.g. document body, SVG canvas, artboard).

  ## Options

  - `throttle` - Milliseconds between client cursor broadcasts (default `30`).
  - `deadband` - Minimum normalized coordinate delta to broadcast (default `0.0015`).
  """
  @spec collab_cursor_attrs(container_id :: String.t(), opts :: keyword()) :: list()
  def collab_cursor_attrs(container_id \\ "default", opts \\ []) do
    throttle = Keyword.get(opts, :throttle, 30)
    deadband = Keyword.get(opts, :deadband, 0.0015)

    [
      "phx-hook": "LiveCollabCursor",
      "data-collab-container": container_id,
      "data-collab-throttle": to_string(throttle),
      "data-collab-deadband": to_string(deadband)
    ]
  end

  @doc """
  Generates HTML tag attributes to attach the `LiveCollabViewport` hook to any
  scrollable container or document body.

  ## Options

  - `presenter` - Boolean indicating if this client broadcasts scroll coordinates (default `false`).
  - `following` - Client ID string of presenter currently being followed.
  - `throttle` - Milliseconds between scroll broadcasts (default `40`).
  """
  @spec collab_viewport_attrs(container_id :: String.t(), opts :: keyword()) :: list()
  def collab_viewport_attrs(container_id \\ "default", opts \\ []) do
    presenter = Keyword.get(opts, :presenter, false)
    following = Keyword.get(opts, :following)
    throttle = Keyword.get(opts, :throttle, 40)

    attrs = [
      "phx-hook": "LiveCollabViewport",
      "data-collab-container": container_id,
      "data-collab-presenter": to_string(presenter),
      "data-collab-throttle": to_string(throttle)
    ]

    attrs =
      if following do
        attrs ++ ["data-collab-following": to_string(following)]
      else
        attrs
      end

    attrs
  end

  @doc """
  Generates HTML tag attributes to attach the `LiveCollabSelection` hook to a canvas or container.
  """
  @spec collab_selection_attrs(container_id :: String.t(), opts :: keyword()) :: list()
  def collab_selection_attrs(container_id \\ "default", _opts \\ []) do
    [
      "phx-hook": "LiveCollabSelection",
      "data-collab-container": container_id
    ]
  end

  @doc """
  Generates HTML tag attributes for an input to wire up LiveCollab hooks,
  readonly states, and accessibility properties.

  ## Example in standard input or CoreComponents:

      <input
        type="text"
        name="customer[name]"
        {collab_attrs("customer.name", @collab_locks, @collab_client_id)}
      />
  """
  @spec collab_attrs(
          field :: String.t(),
          locks :: Field.locks_map(),
          client_id :: Field.client_id() | nil,
          opts :: keyword()
        ) :: list()
  def collab_attrs(field, locks, client_id, opts \\ []) do
    readonly_on_lock = Keyword.get(opts, :readonly, true)
    locked_by_other = Field.locked_by_other?(locks, field, client_id)
    holder = Field.current_holder(locks, field)
    holder_client = if holder, do: holder.client_id, else: nil

    attrs = [
      "phx-hook": "LiveCollabField",
      "data-collab-field": field,
      "data-collab-locked": to_string(locked_by_other),
      "data-collab-locked-by-client": holder_client || ""
    ]

    attrs =
      if readonly_on_lock and locked_by_other do
        [readonly: "readonly", "aria-readonly": "true"] ++ attrs
      else
        attrs
      end

    attrs
  end

  @doc """
  Generates HTML tag attributes for a table row (`<tr>`) or clickable element container
  to attach `LiveCollabElement` tracking hooks, accessibility labels, and CSS styling variables.

  ## Options

  - `hover_intent` - Debounce in milliseconds for hover intent (e.g. `300`). Omit or `nil` for click/focus only.
  - `type` - Activity type when triggered (`:viewing` or `:selected`). Default `:viewing`.
  """
  @spec collab_row_attrs(
          element_id :: String.t(),
          activities :: Element.activities_map(),
          client_id :: String.t() | nil,
          opts :: keyword()
        ) :: list()
  def collab_row_attrs(element_id, activities, client_id, opts \\ []) do
    active_by_other = Element.active_by_other?(activities, element_id, client_id)
    users = Element.active_users(activities, element_id)
    other_users = Enum.filter(users, &(&1.client_id != client_id))
    primary_user = List.first(other_users)
    hover_intent = Keyword.get(opts, :hover_intent)
    activity_type = Keyword.get(opts, :type, :viewing)

    attrs = [
      "phx-hook": "LiveCollabElement",
      "data-collab-element": element_id,
      "data-collab-type": to_string(activity_type),
      "data-collab-active": to_string(active_by_other)
    ]

    attrs =
      if hover_intent && hover_intent > 0 do
        attrs ++ ["data-collab-hover-intent": to_string(hover_intent)]
      else
        attrs
      end

    attrs =
      if active_by_other and primary_user do
        summary = collaborator_summary(other_users)

        attrs ++
          [
            style: "--collab-element-color: #{primary_user.user_color};",
            "aria-description": "#{summary} on this item"
          ]
      else
        attrs
      end

    attrs
  end

  @doc """
  Convenience alias for `collab_row_attrs/4` on generic elements (cards, containers, sections).
  """
  defdelegate collab_element_attrs(element_id, activities, client_id, opts \\ []),
    to: __MODULE__,
    as: :collab_row_attrs

  defp collaborator_summary([]), do: ""
  defp collaborator_summary([single]), do: "#{single.user_name} is viewing"

  defp collaborator_summary([first, second]) do
    "#{first.user_name} and #{second.user_name} are viewing"
  end

  defp collaborator_summary([first | rest]) do
    "#{first.user_name} and #{length(rest)} others are viewing"
  end

  defp avatar_size_class("xs"), do: "w-5 h-5 text-[10px]"
  defp avatar_size_class("sm"), do: "w-7 h-7 text-xs"
  defp avatar_size_class("md"), do: "w-9 h-9 text-sm"
  defp avatar_size_class("lg"), do: "w-11 h-11 text-base"
  defp avatar_size_class(_), do: "w-9 h-9 text-sm"
end
