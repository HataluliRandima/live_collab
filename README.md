# LiveCollab

[![CI](https://github.com/HataluliRandima/live_collab/actions/workflows/ci.yml/badge.svg)](https://github.com/HataluliRandima/live_collab/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/live_collab.svg)](https://hex.pm/packages/live_collab)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/live_collab)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/HataluliRandima/live_collab/blob/main/LICENSE)

Multiplayer UI primitives for Phoenix LiveView: who is here, who is editing which
field, which rows people are looking at, live cursors, presenter scroll-following
and shared selections.

LiveCollab is built only on `Phoenix.Presence`, `Phoenix.PubSub` and LiveView
hooks. It needs no Redis, no external broker and no third-party service, and it
works across a clustered deployment.

> **Status: pre-1.0.** The API may still change between minor versions. Versions
> before 0.5.0 crash on connected mount against a real `Phoenix.Presence`; use
> 0.5.0 or later. See the [CHANGELOG](CHANGELOG.md).

## Features

| Feature | Transport | Server pieces | Client hook |
| :--- | :--- | :--- | :--- |
| Presence and avatar stack (multi-tab aware) | Presence | `@collab_users`, `<.avatar_stack>` | none |
| Away / idle status | Presence | `<.status_reporter>`, `status` in `@collab_users` | `LiveCollabStatus` |
| Advisory field locks with tie-breaking | Presence | `@collab_locks`, `collab_attrs/4`, `<.field_indicator>`, `validate_not_locked/5` | `LiveCollabField` |
| "Ask to edit" lock handoff | PubSub | `@collab_lock_asks`, `@collab_lock_requests`, `<.field_indicator asks=…>`, `<.lock_requests>` | `LiveCollabField` |
| Conflict-aware forms | PubSub | `broadcast_changes/3`, `@collab_remote_changes`, `<.field_change_notice>` | `LiveCollabField` |
| Row and element activity (viewing / selected / editing) | Presence | `@collab_activities`, `collab_row_attrs/4`, `<.row_indicator>`, `<.element_activity>` | `LiveCollabElement` |
| Live cursors | PubSub | `<.cursor_layer>` | `LiveCollabCursor` |
| Presenter mode and scroll following | PubSub | `<.viewport_container>`, `<.follow_pill>` | `LiveCollabViewport` |
| Shared selection boxes | PubSub | `<.selection_layer>` | `LiveCollabSelection` |
| Observability | `:telemetry` | `LiveCollab.Telemetry` | none |

Two transport paths:

* **Durable state** (who is here, locks, activity) lives in Presence metadata. It
  is replicated across the cluster, rebuilt into assigns and rendered by HEEx.
* **Ephemeral events** (cursors, scroll, selections) are relayed over PubSub and
  pushed straight to the hooks with `push_event/3`. They never touch assigns, so
  they never cause a re-render. A test verifies this on both sender and receivers.

## What it guarantees

Field locks are **advisory**. All nodes agree on the lock holder once Presence has
converged, but two clients can briefly both hold a lock, for example during a
network partition. Use locks to avoid accidental overwrites and to show who is
editing. Enforce on submit with `validate_not_locked/5`, and use optimistic
locking for data that must never be lost. Cursor, scroll and selection events are
best effort. The details are in [Consistency guarantees](guides/guarantees.md).

## Installation

```elixir
# mix.exs
def deps do
  [
    {:live_collab, "~> 0.5.0"}
  ]
end
```

Requirements: Elixir 1.15+, Phoenix 1.7+, Phoenix LiveView 1.0+ (see
[Compatibility](#compatibility)).

```elixir
# config/config.exs
config :live_collab,
  presence: MyAppWeb.Presence   # your `use Phoenix.Presence` module
```

```javascript
// assets/js/app.js
import { LiveCollabHooks } from "live_collab"

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ...LiveCollabHooks }
})
```

The hooks are plain ES modules with no build step and no runtime dependencies.
Phoenix's default esbuild setup resolves `live_collab` from `deps/` through
`NODE_PATH`.

## Quick start

```elixir
defmodule MyAppWeb.OrderLive do
  use MyAppWeb, :live_view
  import LiveCollab.Components

  def mount(%{"id" => id}, _session, socket) do
    order = Orders.get_order!(socket.assigns.current_user, id)   # authorize first

    {:ok,
     socket
     |> assign(:order, order)
     |> LiveCollab.track("order:#{id}", socket.assigns.current_user)}
  end
end
```

`user` is any map with `:id` and `:name`, and optionally `:avatar_url` and
`:color`. Atom or string keys both work. `track/4` sets `@collab_users`,
`@collab_locks`, `@collab_activities`, `@collab_client_id` and related assigns,
and handles every `live_collab:*` event for you. Your own `handle_event/3` and
`handle_info/2` keep working unchanged.

```heex
<.avatar_stack users={@collab_users} max={4} />

<input
  type="text"
  name="order[customer_name]"
  value={@order.customer_name}
  {collab_attrs("order.customer_name", @collab_locks, @collab_client_id)}
/>
<.field_indicator field="order.customer_name" locks={@collab_locks} current_client_id={@collab_client_id} />
```

## Usage

### Away / idle status

```heex
<.status_reporter idle_after={60_000} />
<.avatar_stack users={@collab_users} />
```

A tab is `:away` while its page is hidden or after `idle_after` ms without
pointer, keyboard or scroll activity, and `:active` again on the next
interaction. Each user in `@collab_users` has `status: :active | :away`, and a
user counts as away only if all of their tabs are. `<.avatar_stack>` dims away
users (CSS class `live-collab-away`).

### Field locks and server-side enforcement

`collab_attrs/4` attaches the `LiveCollabField` hook and marks the input
`readonly` while someone else holds it. Focusing a held field is refused at
once. If a concurrent claim wins the tie-break, the hook receives
`live_collab:lock_lost`, blurs the input and dispatches a bubbling
`live_collab:conflict` DOM event you can use for a toast.

```elixir
def handle_event("save", %{"order" => params}, socket) do
  changeset =
    socket.assigns.order
    |> Order.changeset(params)
    |> LiveCollab.validate_not_locked(:customer_name, socket.assigns.collab_locks, socket.assigns.collab_client_id)

  # ...
end
```

### "Ask to edit"

```heex
<.lock_requests requests={@collab_lock_requests} />

<input type="text" name="order[name]" {collab_attrs("order.name", @collab_locks, @collab_client_id)} />
<.field_indicator field="order.name" locks={@collab_locks} current_client_id={@collab_client_id} asks={@collab_lock_asks} />
```

When someone else holds the field, the indicator shows **Ask to edit**. The
holder sees "Bob wants to edit order.name — **Hand over** / **Keep editing**".
Handing over releases the holder's lock and focuses the requester's input,
which claims it. A handoff can only answer a request that was actually received,
and requests are dropped when either person leaves or the lock changes hands.

### Conflict-aware forms

After saving, announce the new values:

```elixir
def handle_event("save", %{"order" => params}, socket) do
  {:ok, order} = Orders.update(socket.assigns.order, params)

  {:noreply,
   socket
   |> assign(:order, order)
   |> LiveCollab.broadcast_changes(%{"order.name" => order.name})}
end
```

In every other open form:

* inputs nobody is editing update and briefly highlight (`collab-remote-updated`);
* if the receiver is editing that field, their text is left alone and
  `<.field_change_notice field="order.name" changes={@collab_remote_changes} />`
  shows "Alice saved “Acme” while you were editing — **Use theirs** / **Keep mine**".

Track with `notify_changes: true` to receive
`{:live_collab, :remote_changes, %{changes: changes, by: by}}` in `handle_info/2`
and reload your data, so the new values survive later re-renders. LiveCollab
never stores data; it only tells the other LiveViews what you saved.

### Row and element activity

```heex
<tr
  :for={item <- @items}
  {collab_row_attrs("item:#{item.id}", @collab_activities, @collab_client_id, hover_intent: 300)}
>
  <td>
    <.row_indicator element={"item:#{item.id}"} activities={@collab_activities} current_client_id={@collab_client_id} />
    {item.name}
  </td>
</tr>
```

A click marks a row `selected`, keyboard focus marks it `viewing`, and editing a
field inside it shows `editing`. `hover_intent` (in milliseconds) debounces
mouse travel, so sweeping across a table does not write to Presence for every row.

### Cursors

```heex
<.cursor_layer container_id="canvas" class="h-[600px] border rounded">
  ...
</.cursor_layer>
```

Coordinates are normalized to the container (`0.0..1.0`), so cursors line up
across screen sizes. Sending is throttled (30 ms by default) with a distance
deadband. Rendering interpolates with `requestAnimationFrame` only while cursors
are moving. Idle cursors fade out, and departed collaborators' cursors are
removed immediately.

### Presenter mode and scroll following

```heex
<.viewport_container container_id="doc" presenter={@collab_spotlight_leader == @collab_client_id} auto_follow class="h-screen overflow-y-auto">
  ...
</.viewport_container>

<.follow_pill
  :if={@collab_spotlight_leader}
  leader_name="Presenter"
  leader_client_id={@collab_spotlight_leader}
  is_following={@following?}
/>
```

Start and stop presenting with `<button phx-click="live_collab:spotlight_lead">`
and `phx-click="live_collab:spotlight_stop"`; LiveCollab handles and authorizes
both. With `auto_follow`, everyone else follows the presenter's scrolling, and
scrolling manually breaks out of follow mode. Presenting is allowed by default and denied for users with
`role: "viewer"` / `"observer"`, `can_present?: false`, or when you assign
`collab_can_present?: false`. Only the current presenter, or a user who may
present, can stop a presentation.

Clients that join after a presentation started are not told about it until the
presenter's next status change (see [Limitations](#limitations)).

### Shared selections

```heex
<.selection_layer container_id="board" class="relative h-[500px]">...</.selection_layer>
```

`<.cursor_layer>` and `<.selection_layer>` render the overlay their hook draws
into, marked `phx-update="ignore"` so LiveView re-renders don't remove it. If you
attach a hook to your own element with `collab_cursor_attrs/2` or
`collab_selection_attrs/2`, add `<LiveCollab.Components.overlay id="..." />`
inside it.

Report the local selection from your own code (normalized coordinates):

```javascript
board.dispatchEvent(new CustomEvent("live_collab:local_selection", {
  bubbles: true,
  detail: { x: 0.1, y: 0.2, width: 0.3, height: 0.1, selected_ids: ["card-1", "card-2"] }
}))
board.dispatchEvent(new CustomEvent("live_collab:local_selection_clear", { bubbles: true }))
```

## Configuration

| Key | Default | Description |
| :--- | :--- | :--- |
| `:presence` | required | Your `Phoenix.Presence` module |
| `:pubsub` | Presence's `:pubsub_server` | `Phoenix.PubSub` server |
| `:topic_prefix` | `"live_collab"` | Prefix for collaboration topics |
| `:max_field_id_length` | `255` | Max bytes for field, element and container ids (max 4096) |
| `:telemetry_rate_per_sec` / `:telemetry_burst_limit` | `50` / `60` | Token bucket for cursor, viewport, selection and spotlight events |
| `:presence_rate_per_sec` / `:presence_burst_limit` | `20` / `40` | Token bucket for events that write to Presence (focus, activity) |
| `:presence_sync_interval_ms` | `50` | Minimum time between collaboration-state rebuilds per LiveView |
| `:clock_skew_tolerance_ms` | `500` | Window within which lock claims are ordered by client id |

Every key can also be passed per call: `LiveCollab.track(socket, resource, user, presence_rate_per_sec: 5)`.
Invalid values raise `ArgumentError`.

## Observability

```elixir
LiveCollab.Telemetry.attach_default_logger()
```

LiveCollab emits `:telemetry` events for sessions, presence rebuilds (duration,
room size, coalesced diffs), lock claims, denials and losses, rate-limited and
rejected client events, and unauthorized presenter attempts. See the
[telemetry guide](guides/telemetry.md) for LiveDashboard metrics.

For a runnable demo with a live diagnostics panel:

```bash
elixir examples/collab_demo.exs   # then open http://localhost:4000/?name=Alice in two windows
```

## Security

All client input is treated as untrusted. Ids are validated against a strict
character set and size, coordinates must be finite and in range, and selection
lists are bounded. Colors must be hex, and avatar URLs must be `http(s)`,
root-relative or `data:image`. Identity always comes from the server.

Each LiveView has two token buckets. The hooks never use `innerHTML` with
collaborator data.

**LiveCollab does not authorize access to your resources.** Check access before
calling `track/4`. Read the full [security model](guides/security.md) and report
vulnerabilities as described in [SECURITY.md](https://github.com/HataluliRandima/live_collab/blob/main/SECURITY.md).

## Performance

Measured on one node (WSL2, 7 GiB RAM, Elixir 1.17.0 / OTP 26.1) with real LiveView
processes, `Phoenix.Presence` and `Phoenix.PubSub`. N LiveViews join one room
one after another, then one of them sends 50 cursor moves. The harness is
`test/bench/room_bench_test.exs`; "before" is 0.4.0 with only the pid fix needed
to run at all.

| N | Version | Join storm converged | Join reductions | Cursor fan-out (50 moves → N−1 clients) | LiveView memory (after GC) |
| ---: | :--- | ---: | ---: | ---: | ---: |
| 10 | before | 1.8 s | 0.15 M | 509 ms¹ | 21 KB / client |
| 10 | 0.5.0 | 0.36 s | 0.09 M | 36 ms | 23 KB / client |
| 100 | before | 17.4 s | 81.7 M | 418 ms | 140 KB / client |
| 100 | 0.5.0 | 2.3 s | 52.1 M | 115 ms | 140 KB / client |
| 500 | before | 464 s | 12.8 B | 942 ms | 364 KB / client |
| 500 | 0.5.0 | 218 s | 8.3 B | 827 ms | 588 KB / client |
| 1000 | both | not measured² | | | |

¹ First measurement of the run; includes warm-up. Treat small-N fan-out figures as noisy.
² The 0.5.0 run was stopped after 21 minutes at 5.7 GB RSS on this 7 GiB machine,
before converging. The "before" run was not attempted; extrapolating from N=500, it
would take over an hour. 1000-collaborator rooms are not supported by this
measurement.

Reductions are BEAM work units (a CPU proxy) summed over all LiveView processes.
Times are single runs of a sequential join storm. Real users join gradually,
so steady-state cost per Presence change matters more than these totals.

What changed: each LiveView applies `presence_diff` payloads to a local replica
instead of calling `Presence.list/1` on every change. `list/1` is a
`GenServer.call` into a Tracker shard that copies the shard's state, so hundreds
of LiveViews listing at once serialized on one process. Rebuilds are throttled
per LiveView. The cost is memory: each LiveView now holds its replica, which is
about 60% more per client at N=500.

How cost scales:

* **Each Presence change** (join, leave, focus) makes every LiveView in the room
  rebuild its derived state (users, locks, activities). That is O(N) per
  LiveView and O(N²) per room. 0.5.0 coalesces and throttles these rebuilds
  (`presence_sync_interval_ms`) but cannot remove the O(N) cost of a rebuild.
* **Each cursor move** is delivered to N - 1 LiveViews and browsers. With
  everyone moving at once, a room handles O(N²) messages per second. Rate limits
  bound the per-client input, not the room total.
* **Memory** per LiveView includes the full collaborator list, so room memory
  grows roughly with N².

In practice, rooms of tens of active collaborators are comfortable. For rooms of
hundreds, measure with your own workload and consider disabling cursors or
limiting room size.

## Compatibility

| | Tested |
| :--- | :--- |
| Elixir / OTP | 1.15.8 / 26, 1.17 / 26, 1.20.1 / 29 |
| Phoenix | 1.8 |
| Phoenix LiveView | 1.2 |
| Browsers | Evergreen browsers (hooks are ES2015+ modules; JS tests run under jsdom, not real browsers) |

Other versions allowed by the dependency requirements are expected to work but
are not covered by the test matrix.

## Limitations

* Locks are advisory, and all cross-node guarantees are eventual (see
  [guarantees](guides/guarantees.md)).
* Presenter state is not persisted. Late joiners learn about a presentation only
  from the next spotlight event.
* One tracked resource per LiveView process.
* Room size directly drives CPU and memory (see [Performance](#performance)).

## Development

```bash
mix deps.get && npm ci
mix test                                       # unit + LiveView integration tests
epmd -daemon && mix test --only distributed    # multi-node tests (:peer)
npm test                                       # JS hooks (node:test + jsdom)
mix credo --strict && mix dialyzer
```

See [CONTRIBUTING.md](https://github.com/HataluliRandima/live_collab/blob/main/CONTRIBUTING.md).

## License

MIT. See [LICENSE](https://github.com/HataluliRandima/live_collab/blob/main/LICENSE).
