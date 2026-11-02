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
| **Durable Collaborative State** | `Phoenix.Presence` (CRDT) | User joins/leaves, active presence, field-level locks, element/row activity | Low frequency; safely updates LiveView assigns |
| **High-Frequency Ephemeral Telemetry** | `Phoenix.PubSub` + Client JS | Mouse coordinates, collaborative cursors, scroll/viewport telemetry | Zero LiveView render cycles or diff storms; rendered directly in JS |

---

## Features

### Version 1.0 (Presence & Field-Level Collaboration)
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

### Version 1.1 (Element & Table-Row Activity Indicators)
- **Shared Multi-User Presence**: Multiple collaborators can simultaneously view or select the same table row, card, or document section.
- **Row Activity Indicators (`<LiveCollab.Components.row_indicator />`)**: Displays compact stacked avatars on table rows showing who is currently viewing, selecting, or editing cells in that row.
- **Anti-Diff-Storming Hover Intent**: Debounced hover intent in client hooks (`LiveCollabElement`) ensures moving the mouse across 100 table rows causes zero Presence diff storms.
- **Dynamic CSS Variable Theming**: `collab_row_attrs/4` injects `--collab-element-color` for custom border or background highlighting.

---

## Installation

Add `live_collab` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:live_collab, "~> 0.1.1"}
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
      # Automatically initializes @collab_users, @collab_locks, and @collab_activities:
      |> LiveCollab.track("order:#{id}", current_user)

    {:ok, socket}
  end
end
```

---

### 2. Render the Avatar Stack

```heex
<LiveCollab.Components.avatar_stack
  users={@collab_users}
  max={4}
  size="md"
/>
```

---

### 3. Add Table-Row Activity Indicators

Add collaborative awareness to table rows:

```heex
<table class="min-w-full divide-y divide-gray-200">
  <tbody class="divide-y divide-gray-200">
    <tr
      :for={item <- @order.items}
      class="transition-colors hover:bg-gray-50 data-[collab-active=true]:border-l-4"
      {LiveCollab.Components.collab_row_attrs("item:#{item.id}", @collab_activities, @collab_client_id, hover_intent: 300)}
    >
      <td class="px-4 py-3 flex items-center gap-2">
        <%!-- Shows avatars of collaborators viewing or editing this row --%>
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

> [!TIP]
> Setting `hover_intent: 300` ensures that rapid cursor travel over the table never triggers unnecessary Presence updates or diff recalculations. Only intentional focus, click, or resting hover (>300ms) will activate the indicator.

---

### 4. Add Collaborative Form Inputs

Use `collab_attrs/4` on your inputs and render `<.field_indicator />`:

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

### 5. Server-Side Changeset Enforcement (Security)

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

## Adversarial Design & Failure Mitigations

1. **Deterministic CRDT Tie-Breaking**:
   If Alice and Bob focus a field simultaneously, both nodes resolve the claim deterministically on `{acquired_at, client_id}`. The identical winner is elected on every node. The loser receives `live_collab:lock_lost` and transitions to readonly.

2. **Process-Monitored Lifecycle**:
   Erlang monitors track the LiveView PID. When a tab crashes, browser closes, or device disconnects, field locks and row activity are instantaneously purged by `Phoenix.Tracker`. Zero orphan locks or stale state.

3. **Multi-Tab Isolation**:
   Browser tabs generate isolated `client_id`s in `sessionStorage`. If the same user has two tabs open, Tab 2 is locked out if Tab 1 holds the field, preventing self-overwrites.

4. **Malicious Input Defense**:
   All field and element identifiers are sanitized against an alphanumeric/separator whitelist, with strict byte limits (max 255 chars) to prevent XSS, memory exhaustion, and payload bombing.

---

## Roadmap

- **V1.0 (Complete)**: Presence tracking, accessible avatar stack, field-level collaboration & advisory locks, server-side validation.
- **V1.1 (Complete)**: Element & table-row activity indicators (`<LiveCollab.Components.row_indicator />`, anti-diff hover intent).
- **V2.0**: High-performance collaborative cursors via client-side SVG rendering & PubSub broadcast (zero LiveView assigns diffing).
- **V3.0**: Viewport & scroll following, multiplayer selection containers.

---

## License

MIT © LiveCollab Contributors
