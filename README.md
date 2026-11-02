# LiveCollab

[![Hex.pm](https://img.shields.io/hexpm/v/live_collab.svg)](https://hex.pm/packages/live_collab)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/live_collab)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

**LiveCollab** brings real-time multiplayer UI primitives to Phoenix LiveView applications.

Built entirely on Phoenix's native primitives—`Phoenix.Presence`, `Phoenix.PubSub`, and LiveView hooks—LiveCollab requires **no Redis, external WebSocket brokers, or third-party cloud services**.

---

## Architectural Principles

LiveCollab enforces a strict separation between two categories of collaborative events:

| Category | Transport / Engine | Typical Events | LiveView Lifecycle & Diff Impact |
| :--- | :--- | :--- | :--- |
| **Durable Collaborative State** (Path 1) | `Phoenix.Presence` (CRDT) | User joins/leaves, active presence, field-level locks, element/row activity | Low frequency; safely updates LiveView assigns and renders reactive components |
| **High-Frequency Ephemeral Telemetry** (Path 2) | `Phoenix.PubSub` + Client JS + `RateLimiter` | Mouse coordinates, collaborative cursors, scroll/viewport telemetry, selection marquees | **Zero assigns diffing or template re-renders; rendered directly in client JS; protected at socket boundary by token-bucket rate limiter** |

---

## Features

### Version 0.4.0 (Security Hardened & Cluster Resilient)
- **Token Bucket Telemetry Rate Limiter (`LiveCollab.RateLimiter`)**: Purely functional in-memory token bucket directly in socket assigns ($O(1)$ monotonic arithmetic, zero GenServer/ETS overhead) that drops telemetry floods at the socket boundary before cluster PubSub saturation can occur.
- **Multi-Node Cluster Clock-Skew Mitigation**: Replaces naive millisecond comparison with windowed bucketing in `LiveCollab.Field.resolve_conflict/2` (`clock_skew_tolerance_ms: 500`), guaranteeing identical deterministic tie-breaking across all nodes regardless of NTP drift or message arrival order.
- **Client ID Injection Defense**: Completely ignores untrusted wire `params["client_id"]`, strictly enforcing server-authenticated `sock.assigns[:collab_client_id]`.
- **Spotlight Authorization Guards**: Prevents unprivileged attendees (`role: "viewer"`, `collab_can_present?: false`) from hijacking viewports or disrupting ongoing presentations.
- **Selection Marquee Bounding**: Sanitizes and truncates collaborative selection arrays to at most 100 items and 255 bytes per ID, neutralizing memory exhaustion attacks.
- **Lock Seniority Preservation**: Re-focusing an already held field in `Phoenix.Presence` preserves the original `acquired_at` timestamp rather than resetting lock seniority.

### Version 0.3.0 (Viewport Following & Multiplayer Selection Containers)
- **Viewport & Scroll Following**: Presenters can lead followers through documents, canvases, or dashboards with smooth, programmatic scroll synchronization.
- **Normalized Scroll Coordinates `[0.0, 1.0]`**: Eliminates coordinate distortion across differing display dimensions, aspect ratios, and responsive text layouts.
- **Infinite Loop Feedback Suppression**: Programmatic follower scrolling suppresses local scroll event broadcasts, preventing cascading feedback loops.
- **Follower Manual Breakout**: If a follower manually scrolls or wheels, follow mode gracefully disengages without fighting the user.
- **Multiplayer Selection Containers (`<LiveCollab.Components.selection_layer />`)**: Real-time bounding boxes and marquee selections rendered in each collaborator's deterministic color with a floating username badge.

### Version 0.2.0 (High-Performance Collaborative Cursors)
- **Zero Assigns Diffing**: High-frequency cursor messages bypass LiveView's assign diffing engine entirely via direct `push_event/3` dispatch. Zero template re-renders and zero Morphdom DOM overhead.
- **Normalized Container Coordinates `[0.0, 1.0]`**: Cursor coordinates are transmitted relative to target containers, guaranteeing precise visual alignment across differing monitor sizes, responsive layouts, and zoom levels.
- **Client-Side Throttling & Distance Deadband**: Limits transmission to 30ms (~33 fps) and skips broadcasts when mouse movement is below threshold, keeping network traffic minimal.
- **Hardware-Accelerated 60/120 FPS Interpolation**: Uses `requestAnimationFrame` and linear interpolation (`lerp`) on the browser for butter-smooth cursor motion.
- **Crisp SVG Pointers & Name Pills**: Renders Figma-style SVG cursors colored with each user's deterministic palette color and displaying their name tag.
- **Inactivity Timeout & Leave Cleanup**: Cursors automatically fade out after 4 seconds of inactivity and clear immediately when the pointer leaves the container.

### Version 0.1.0 (Presence & Field-Level Collaboration)
- **Collaborative Presence Tracking**: Clean, single-line API (`LiveCollab.track/3`) for tracking users viewing the same resource.
- **Multi-Tab Isolation**: Transparently handles multiple tabs from the same user without identity or lock collisions via isolated client UUIDs.
- **Avatar Stack Component (`<LiveCollab.Components.avatar_stack />`)**: Accessible, customizable avatar stack with deterministic colors, initial fallbacks, and overflow counters (`+3`).
- **Field-Level Collaboration & Advisory Locking**:
  - Automatically associates focused inputs with the active user.
  - Broadcasts visual editing indicators to other collaborators.
  - Optional client-side readonly locking and accessible `aria-readonly` attributes.
  - **Deterministic Conflict Resolution (CRDT Tie-Breaking)**: Resolves race conditions and network split-brain collisions consistently across all cluster nodes without central coordination.
  - **No Zombie Locks**: Process monitoring ensures locks are immediately released on tab close, navigation, or server crashes.
  - **Server-Side Changeset Protection**: `LiveCollab.Field.validate_not_locked/5` prevents unauthorized form submissions even if client HTML attributes are tampered with.

---

## Installation

Add `live_collab` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:live_collab, "~> 0.4.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

---

## Configuration

In `config/config.exs`:

```elixir
config :live_collab,
  presence: MyAppWeb.Presence,
  pubsub: MyApp.PubSub,
  topic_prefix: "live_collab",
  max_field_id_length: 255,
  telemetry_rate_per_sec: 50,
  telemetry_burst_limit: 60,
  clock_skew_tolerance_ms: 500
```

---

## Client JavaScript Setup

In your `assets/js/app.js`:

```javascript
import { LiveSocket } from "phoenix_live_view"
import { Socket } from "phoenix"
import { LiveCollabHooks } from "live_collab"

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ...LiveCollabHooks }
})

liveSocket.connect()
```

---

## Usage Guide

### 1. Viewport & Scroll Following (Presentation Mode)

Wrap long documents or dashboards with `<.viewport_container>` and display a `<.follow_pill>`:

```heex
<%!-- Follow pill showing the presenter with a toggle button --%>
<%= if @presenter do %>
  <LiveCollab.Components.follow_pill
    leader_name={@presenter.name}
    leader_client_id={@presenter.client_id}
    leader_color={@presenter.color}
    is_following={@is_following}
  />
<% end %>

<%!-- Synchronized scroll viewport container --%>
<LiveCollab.Components.viewport_container
  container_id="doc_reader"
  presenter={@is_presenter}
  following={if @is_following, do: @presenter.client_id, else: nil}
  class="overflow-y-auto h-[600px] border rounded-lg p-6 bg-white"
>
  <div class="prose max-w-none">
    <h1>Collaborative Document</h1>
    <p>Scroll down to see followers match your position smoothly...</p>
    <div style="height: 2000px;"></div>
  </div>
</LiveCollab.Components.viewport_container>
```

> [!TIP]
> If a follower manually scrolls with their mouse wheel, `LiveCollabViewport` automatically disengages follow mode without fighting the user or echoing scroll events back to the presenter.

---

### 2. Multiplayer Selection Containers

Display real-time bounding boxes when collaborators select items or drag marquee rects:

```heex
<LiveCollab.Components.selection_layer
  container_id="design_board"
  class="w-full h-[500px] border rounded-lg bg-gray-50"
>
  <div class="p-6 grid grid-cols-3 gap-4">
    <div class="p-4 bg-white shadow rounded">Card 1</div>
    <div class="p-4 bg-white shadow rounded">Card 2</div>
    <div class="p-4 bg-white shadow rounded">Card 3</div>
  </div>
</LiveCollab.Components.selection_layer>
```

---

### 3. Collaborative Cursors (Zero Diff Overhead)

```heex
<LiveCollab.Components.cursor_layer
  container_id="project_canvas"
  class="w-full h-[600px] border border-gray-200 rounded-lg shadow-sm bg-white overflow-hidden"
>
  <div class="p-8">
    <h2 class="text-xl font-bold">Collaborative Canvas</h2>
    <p class="text-gray-600">Move your cursor to see multiplayer pointers in real-time!</p>
  </div>
</LiveCollab.Components.cursor_layer>
```

---

### 4. Collaborative Presence & Avatar Stack

```elixir
defmodule MyAppWeb.OrderLive.Edit do
  use MyAppWeb, :live_view

  def mount(%{"id" => id}, _session, socket) do
    order = Orders.get_order!(id)
    current_user = socket.assigns.current_user

    socket =
      socket
      |> assign(:order, order)
      # Automatically initializes @collab_users, @collab_locks, and @collab_activities:
      |> LiveCollab.track("order:#{id}", current_user)

    {:ok, socket}
  end
end
```

In your HEEx template:

```heex
<LiveCollab.Components.avatar_stack
  users={@collab_users}
  max={4}
  size="md"
/>
```

---

### 5. Table-Row Activity Indicators

```heex
<table class="min-w-full divide-y divide-gray-200">
  <tbody class="divide-y divide-gray-200">
    <tr
      :for={item <- @order.items}
      class="transition-colors hover:bg-gray-50 data-[collab-active=true]:border-l-4"
      {LiveCollab.Components.collab_row_attrs("item:#{item.id}", @collab_activities, @collab_client_id, hover_intent: 300)}
    >
      <td class="px-4 py-3 flex items-center gap-2">
        <LiveCollab.Components.row_indicator
          element={"item:#{item.id}"}
          activities={@collab_activities}
          current_client_id={@collab_client_id}
        />
        <span><%= item.name %></span>
      </td>
      <td class="px-4 py-3 text-right"><%= item.quantity %></td>
    </tr>
  </tbody>
</table>
```

---

### 6. Collaborative Form Inputs & Advisory Locks

```heex
<div class="space-y-1">
  <div class="flex items-center justify-between">
    <label class="block text-sm font-medium text-gray-700">Customer Name</label>
    <.field_indicator
      field="order.customer_name"
      locks={@collab_locks}
      current_client_id={@collab_client_id}
    />
  </div>

  <input
    type="text"
    name="order[customer_name]"
    value={@order.customer_name}
    class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
    {LiveCollab.Components.collab_attrs("order.customer_name", @collab_locks, @collab_client_id)}
  />
</div>
```

---

### 7. Server-Side Changeset Enforcement (Security)

Prevent unauthorized submissions by checking locks inside `phx-change` or `phx-submit`:

```elixir
def handle_event("save", %{"order" => order_params}, socket) do
  changeset =
    socket.assigns.order
    |> Order.changeset(order_params)
    |> LiveCollab.validate_not_locked(
      :customer_name,
      socket.assigns.collab_locks,
      socket.assigns.collab_client_id
    )

  if changeset.valid? do
    {:noreply, socket}
  else
    {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
```

---

### 8. Spotlight & Presentation Permissions

By default, any tracked user can lead a presentation. In environments with role-based access control, restrict viewer or observer attendees:

```elixir
# Option A: Assign permission flag on socket
socket = assign(socket, :collab_can_present?, false)

# Option B: Pass role in user map
LiveCollab.track(socket, "doc:123", %{id: user.id, name: user.name, role: "viewer"})
```

If an unauthorized attendee fires `"live_collab:spotlight_lead"`, the server rejects the request, pushes `"live_collab:spotlight_unauthorized"` back to the client, and drops the broadcast. Furthermore, only the active leader or an authorized presenter/admin can emit `"live_collab:spotlight_stop"` to terminate an ongoing presentation.

---

## Adversarial Design & Failure Mitigations

1. **Path 2 Zero-Diffing Boundary & Mailbox Protection**:
   High-frequency telemetry (cursors, viewports, selections) travels strictly over `Phoenix.PubSub` directly to client JS hooks via `push_event/3`. `socket.assigns` is **never** mutated during telemetry, eliminating HEEx template re-render storms and DOM reconciliation.
2. **Token Bucket Rate Limiting (`LiveCollab.RateLimiter`)**:
   Purely functional in-memory token buckets in socket assigns ($O(1)$ monotonic arithmetic) protect the LiveView mailbox and cluster PubSub against flood attacks from malicious or unthrottled clients. Telemetry exceeding configured rate limits is dropped at the socket boundary.
3. **Multi-Node Cluster Clock-Skew Hardening**:
   Replaces fragile raw millisecond ordering with windowed bucketing (`clock_skew_tolerance_ms: 500`). Competing focus claims arriving within the concurrency window break ties deterministically on `{bucket, client_id, user_id}`, rendering tie-breaking immune to NTP drift between cluster nodes.
4. **Untrusted Client ID Parameter Injection Immunity**:
   Wire-level `params["client_id"]` payloads are completely ignored across all event handlers. The server strictly uses `sock.assigns[:collab_client_id]`, preventing identity spoofing, lock theft, or tie-break rigging.
5. **Presence Untrack Key Parity & No Zombie Locks**:
   `Presence.untrack` is guaranteed to target the tracked `user_key` rather than the tab `client_id`, cleanly purging presence state upon departure. Process monitors purge locks immediately if a tab or node crashes.
6. **Lock Seniority Preservation**:
   Re-focusing an existing field preserves the original `acquired_at` timestamp in `Phoenix.Presence`, preventing lock seniority flapping during form re-renders.
7. **Infinite Scroll Feedback Defense**:
   When programmatic scrolling is applied to follow a leader, an internal guard suppresses local scroll broadcasts, eliminating infinite feedback ping-pong loops.
8. **Multi-Tab Isolation**:
   Browser tabs generate isolated `client_id`s in `sessionStorage`. If the same user has two tabs open, Tab 2 is locked out if Tab 1 holds the field, preventing self-overwrites.
9. **Malicious Input Defense & Bounded Payloads**:
   All field, element, coordinate, scroll, and selection parameters are strictly validated and bounded (preventing NaN, infinite coordinates, XSS, and payload bombing with max 100 selection items and 255 bytes per ID).

---

## License

MIT © LiveCollab Contributors
