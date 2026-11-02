defmodule LiveCollab.Components do
  @moduledoc """
  Functional HEEx components for LiveCollab.

  Designed to be accessible, zero-dependency, and easily styled using Tailwind CSS,
  custom CSS variables, or custom utility classes.
  """

  use Phoenix.Component
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

  defp avatar_size_class("xs"), do: "w-5 h-5 text-[10px]"
  defp avatar_size_class("sm"), do: "w-7 h-7 text-xs"
  defp avatar_size_class("md"), do: "w-9 h-9 text-sm"
  defp avatar_size_class("lg"), do: "w-11 h-11 text-base"
  defp avatar_size_class(_), do: "w-9 h-9 text-sm"
end
