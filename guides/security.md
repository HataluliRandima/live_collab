# Security model

## Trust boundaries

| Source | Trusted? | Notes |
| :--- | :--- | :--- |
| The `user` map you pass to `LiveCollab.track/4` | Partly | Your code chooses it, but fields such as `:name` and `:color` usually come from user profiles. Colors and avatar URLs are sanitised; names are treated as text. |
| `live_collab:*` events from the browser | **No** | Every parameter is validated. Identity is never taken from the client. |
| Messages from other nodes (PubSub / Presence) | Yes | These come from your own cluster. Payloads are still shape-checked before being pushed to browsers. |
| Server-pushed data rendered by the JS hooks | **No** | Hooks render other users' names and colors, so they treat them as untrusted. |

## Identity

* `client_id` is generated on the server (`:crypto.strong_rand_bytes/1`) for
  every connected LiveView. It is never read from client params, so a client
  cannot impersonate another tab, steal a lock or rig a tie-break.
* The user id, name and color in relayed payloads come from the server-side
  `user` map, not from the event.

## Input validation

| Input | Rule |
| :--- | :--- |
| Field ids | `[A-Za-z0-9_.\-:\[\]]`, no `..`, at most `max_field_id_length` bytes (default 255) |
| Element, container and anchor ids | Same, plus `/` |
| Coordinates | Finite numbers; integers within ±1e15; numeric strings of at most 32 bytes; range-checked per event |
| `selected_ids` | Only the first 400 items are inspected; at most 100 are kept, each a valid UTF-8 string of 1–255 bytes (others are dropped, never truncated) |
| Colors | `#rgb` or `#rrggbb` only, normalised to `#rrggbb`. Anything else is replaced by the deterministic palette color. |
| Avatar URLs | `http(s)://`, root-relative `/…` or `data:image/…`. Anything else is dropped. |

Invalid events are dropped and reported as `[:live_collab, :event, :rejected]`
telemetry. Unknown `live_collab:*` events and known events with missing
parameters are absorbed as well, so they can never reach your `handle_event/3`.

## Denial of service

Each LiveView has two token buckets in `socket.private`:

* **telemetry** (default 50/s, burst 60): cursor, viewport, selection,
  `cursor_left`, `selection_clear` and spotlight events;
* **presence** (default 20/s, burst 40): field focus and element activity. Each
  of these writes to Presence, which is replicated to every node and causes
  every collaborator to rebuild its state, so this bucket is smaller.

Releases (`field_blur`, `element_inactive`) are never limited, because dropping
one would leave a stale lock. They only write when something is actually held,
so they cannot be used to amplify load.

Presence rebuilds are throttled per LiveView (`presence_sync_interval_ms`), which
bounds the CPU a burst of joins or focus changes can cost each collaborator.

What LiveCollab does not do:

* It does not limit how many LiveViews may join one room. Rebuild cost and
  memory grow with room size (see the benchmarks in the README). Enforce room
  limits in your application if rooms can be large.
* It does not cap WebSocket frame sizes. Configure `:max_frame_size` on your
  endpoint's socket if you need a hard limit on message size.

## Authorization

LiveCollab answers "who is collaborating", not "who may see this document".
**Authorize access to the resource before calling `track/4`.** Anyone who can
mount the LiveView joins the room and sees collaborators' names, colors, avatars
and cursor positions.

Spotlight (presenter mode) is allowed by default. It is denied when
`@collab_can_present?` or `@can_present?` is `false`, when the user has
`can_present?: false`, or when the user's role is `viewer` or `observer`. Only
the current leader, or a user who may present, can stop a presentation. A client
that does not know of an active presentation cannot stop one.

## Browser

* The hooks never use `innerHTML` with server data. Names are written with
  `textContent`, and colors are re-validated against `#rrggbb`.
* `<.follow_pill>` uses `Phoenix.LiveView.JS.dispatch/2` instead of an inline
  `onclick`, so it works under a strict Content-Security-Policy and cannot be
  turned into a script injection.

## Reporting vulnerabilities

See [SECURITY.md](https://github.com/HataluliRandima/live_collab/blob/main/SECURITY.md).
