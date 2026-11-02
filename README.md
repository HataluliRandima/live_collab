# LiveCollab

[![Hex.pm](https://img.shields.io/hexpm/v/live_collab.svg)](https://hex.pm/packages/live_collab)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/live_collab)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

**LiveCollab** brings real-time multiplayer UI primitives to Phoenix LiveView applications.

Built entirely on Phoenix's native primitives—`Phoenix.Presence`, `Phoenix.PubSub`, and LiveView hooks—LiveCollab requires **no Redis, external WebSocket brokers, or third-party cloud services**.

---

## Architectural Principles

LiveCollab enforces a strict separation between two categories of collaborative events:

| Category | Transport / Engine | Typical Events | LiveView Diff Impact |
| :--- | :--- | :--- | :--- |
| **Durable Collaborative State** | `Phoenix.Presence` (CRDT) | User joins/leaves, active presence, field-level locks, element activity | Low frequency; safely updates LiveView assigns |
| **High-Frequency Ephemeral Telemetry** | `Phoenix.PubSub` + Client JS | Mouse coordinates, collaborative cursors, scroll/viewport telemetry | Zero LiveView render cycles or diff storms; rendered directly in JS |

---

## Features (Version 1.0)

- **Collaborative Presence Tracking**: Clean, single-line API for tracking users viewing the same resource.
- **Multi-Tab Isolation**: Transparently handles multiple tabs from the same user without identity or lock collisions.
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
    {:live_collab, "~> 0.1.0"}
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
  max_field_id_length: 255
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

### 1. Track Collaborative Presence in your LiveView

```elixir
defmodule MyAppWeb.OrderLive.Edit do
  use MyAppWeb, :live_view

  def mount(%{"id" => id}, _session, socket) do
    order = Orders.get_order!(id)
    current_user = socket.assigns.current_user

    socket =
      socket
      |> assign(:order, order)
      |> LiveCollab.track("order:#{id}", current_user)

    {:ok, socket}
  end
end
```

`LiveCollab.track/3` automatically:
1. Subscribes to the collaboration topic.
2. Tracks the LiveView process in `Phoenix.Presence`.
3. Populates `@collab_users` and `@collab_locks` assigns.
4. Attaches lifecycle event and info hooks to handle field focus, blur, and presence synchronization.

---

### 2. Render the Avatar Stack

In your HEEx template:

```heex
<LiveCollab.Components.avatar_stack
  users={@collab_users}
  max={4}
  size="md"
/>
```

#### Custom Slot Styling

```heex
<LiveCollab.Components.avatar_stack users={@collab_users} max={3}>
  <:user_avatar :let={user}>
    <div class="relative group">
      <img src={user.avatar_url || "/images/default-avatar.png"} class="w-8 h-8 rounded-full border-2 border-white" />
      <span class="tooltip">{user.name}</span>
    </div>
  </:user_avatar>
  <:overflow_indicator :let={count}>
    <span class="badge">+{count} others</span>
  </:overflow_indicator>
</LiveCollab.Components.avatar_stack>
```

---

### 3. Add Collaborative Form Inputs

Use the `collab_attrs/4` helper on your inputs and render `<.field_indicator />`:

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

### 4. Server-Side Changeset Enforcement (Security)

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
    # Proceed with save
    {:noreply, socket}
  else
    {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
```

---

## Adversarial Design & Failure Mitigations

1. **Deterministic CRDT Tie-Breaking**:
   If Alice and Bob focus a field at the identical millisecond or during a network partition, both nodes resolve the claim on `{acquired_at, client_id}`. The identical winner is elected on every node. The loser's client hook receives a `live_collab:lock_lost` event and transitions to readonly.

2. **Tab Crash & Unregister**:
   Erlang process monitors track the LiveView PID. When a tab crashes, browser closes, or device disconnects, the lock is instantly revoked by `Phoenix.Tracker`. Zero orphan locks or stale state.

3. **Multi-Tab Isolation**:
   Browser tabs generate isolated `client_id`s in `sessionStorage`. If the same user has two tabs open, Tab 2 is locked out if Tab 1 holds the field, preventing self-overwrites.

4. **Malicious Input Defense**:
   All field identifiers are sanitized against an alphanumeric/separator whitelist, with strict byte limits (max 255 chars) to prevent XSS, memory exhaustion, and payload bombing.

---

## Roadmap

- **V1 (Current)**: Presence tracking, accessible avatar stack, field-level collaboration & advisory locks, server-side validation.
- **V1.x**: Element & table-row activity indicators ("Alice is viewing Row 4").
- **V2**: High-performance collaborative cursors via client-side SVG rendering & PubSub broadcast (zero LiveView assigns diffing).
- **V3**: Viewport & scroll following, multiplayer selection containers.

---

## License

MIT © LiveCollab Contributors
