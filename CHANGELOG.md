# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-11-19

Earlier versions were only tested against an in-memory Presence mock and **crashed
on every connected mount against a real `Phoenix.Presence`**. Upgrading is strongly
recommended. See `guides/guarantees.md` for what LiveCollab does and does not guarantee.

### Fixed
- **Critical:** `track/4` passed the LiveView socket to `Phoenix.Tracker`, which
  requires a pid (`FunctionClauseError` on connected mount). The same bug affected
  untrack/update. Without an explicit `:pubsub`, `track/4` also raised; the PubSub
  server is now read from the Presence module.
- **Security:** stored XSS in the cursor hook (`innerHTML` with user names/colors);
  CSS injection via unvalidated user colors; inline-JS `onclick` in `<.follow_pill>`;
  a late-joining viewer could stop an active presentation; unvalidated
  `container_id`/`anchor_element_id` rebroadcast to all peers; `String.to_atom/1`
  on field names; unknown or malformed `live_collab:*` events reached (and could
  crash) the app's `handle_event/3`; several events were not rate limited.
- Tabbing between fields released the newly focused field's lock (late blur).
- `Field.resolve_conflict/2` depended on the local clock, so nodes could disagree.
- Re-tracking raised (hooks attached twice); in-flight messages for an old topic
  crashed the app's `handle_info/2` after untrack/re-track.
- `RateLimiter` accepted invalid rates, bursts and negative costs, and could
  double-credit time.
- JS: lock leak when a field was destroyed during the blur debounce; duplicate
  `lock_lost` handling; departed cursors and selections never removed; a perpetual
  `requestAnimationFrame` loop; listener leaks; `pushEvent` throwing after disconnect.
- `import "live_collab"` could not resolve (`package.json` was not at the package root).
- No hook could mount in a real browser: LiveView requires a DOM `id` on every
  `phx-hook` element, and none of the helpers or components rendered one. They
  now emit a deterministic id (override with `id: "..."`, omit with `id: false`).

### Changed
- High-frequency events no longer re-render the sender: rate-limiter state moved
  from assigns to `socket.private` (`@collab_rate_limiter` removed).
- Each LiveView keeps a local replica of the room's Presence entries, updated from
  `presence_diff` payloads, instead of calling `Presence.list/1` (a `GenServer.call`
  into a Tracker shard) on every change; rebuilds are coalesced and throttled
  (`presence_sync_interval_ms`, default 50). Measured join-storm convergence:
  N=100 17.4 s → 2.3 s, N=500 464 s → 218 s; memory per LiveView is higher (see README).
- Separate rate-limit bucket for Presence writes (`presence_rate_per_sec` 20, `presence_burst_limit` 40).
- Configuration is validated; invalid values raise `ArgumentError`.
- `sanitize_selected_ids/1` drops oversized ids instead of truncating them.
- `use LiveCollab.LiveView` only imports components (the injected callbacks were unreachable).
- JS hooks no longer send a client-side `client_id`; follow events are handled on `window`.
- Requires Elixir `~> 1.15` and `phoenix_live_view ~> 1.0`.

### Added
- `LiveCollab.Telemetry`: events for sessions, presence rebuilds, locks, rate-limited
  and rejected events, and spotlight; `attach_default_logger/1`.
- `live_collab:peers_left` push event; immediate `lock_lost` when focusing a held field;
  `live_collab:local_selection` DOM API for reporting selections.
- Integration tests against a real Presence, multi-node tests (`:peer`), JS hook tests,
  benchmarks, CI, and CONTRIBUTING / SECURITY / CODE_OF_CONDUCT and guides.

## [0.4.0] - 2026-11-02

### Security & Hardening (Red Team Remediation)
- **Client ID Injection Defense**: Wire-level parameter `params["client_id"]` is completely ignored across all event handlers (`field_focus`, `field_blur`, `element_active`, `element_inactive`, `cursor_move`, `cursor_left`, `viewport_move`, `spotlight_lead`, `spotlight_stop`, `selection_move`, `selection_clear`), strictly enforcing server-side `sock.assigns[:collab_client_id]`.
- **Presence Untrack Key Parity**: Fixed defect in `LiveCollab.LiveView.untrack/2` where client_id was passed instead of user_key, leaving ghost sessions in `Phoenix.Presence`. Sessions are now tracked and untracked via `socket.assigns[:collab_user_key]`.
- **Spotlight Authorization Guards**: Added `authorized_spotlight_leader?/2` and `can_stop_spotlight?/3` in `LiveCollab.LiveView`. Unprivileged viewers (`role: "viewer"`, `collab_can_present?: false`) are rejected from claiming or terminating spotlight broadcasts.
- **Selection Marquee Bounding**: Added `LiveCollab.Viewport.sanitize_selected_ids/1` capping selection arrays at 100 items and truncating IDs at 255 bytes to eliminate payload bombing and memory exhaustion risks.
- **Functional Token Bucket Rate Limiter**: Added `LiveCollab.RateLimiter` managing in-memory token buckets in socket assigns. Drops flood telemetry bursts beyond configured limits (default: 50 events/sec, 60 burst) without GenServer or ETS overhead.
- **Multi-Node Cluster Clock-Skew Hardening**: Hardened `LiveCollab.Field.resolve_conflict/2` with windowed bucketing (`clock_skew_tolerance_ms: 500`). Claims arriving within the concurrency window break ties deterministically by `client_id` rather than raw drifting milliseconds.
- **Lock Seniority Preservation**: Re-focusing an already locked field in `Presence.update_field/6` preserves `acquired_at` rather than resetting seniority.
- **Lifecycle Hook Arity Fix**: Aligned `attach_collab_event_hook` invocation in `track/4` to arity 4.
- **Hex Metadata Alignment**: Corrected repository URLs to `https://github.com/HataluliRandima/live_collab`, added MIT `LICENSE` file, and synchronized `package.json` version.

## [0.3.0] - 2026-11-02

### Added
- **Viewport & Scroll Following (Screen / Presentation Mode)**:
  - `LiveCollab.Viewport` module for validating normalized scroll coordinates and constructing sanitized viewport payloads.
  - Normalized scroll positions `[0.0, 1.0]` across responsive layouts, differing monitor sizes, and zoom levels.
  - `<LiveCollab.Components.viewport_container />` functional component for wrapping synchronized scrollable areas.
  - `<LiveCollab.Components.follow_pill />` interactive component indicating active presenter with follow/unfollow toggle.
  - Client-side hook `LiveCollabViewport`:
    - Throttled scroll tracking (40ms).
    - Infinite scroll loop feedback suppression via programmatic scroll guards (`isProgrammaticScroll`).
    - Follower manual scroll auto-breakout: immediately exits follow mode when user manually rolls mouse wheel or drags scrollbar.
    - Smooth scrolling via native `scrollTo({ behavior: 'smooth' })`.
- **Multiplayer Selection Containers**:
  - `LiveCollab.Viewport.validate_selection/4` and `build_selection_payload/7` for managing real-time collaborative selection bounding boxes.
  - `<LiveCollab.Components.selection_layer />` and `collab_selection_attrs/2` for attaching multiplayer selection overlays.
  - Client-side hook `LiveCollabSelection`:
    - Renders translucent selection boxes with border and background in the collaborator's deterministic color.
    - Floating name badge attached to selection marquee.
    - Automatic 5-second inactivity fadeout and instantaneous clear handling.
- **Unit & Adversarial Tests**:
  - Tests verifying rejection of malicious/extreme scroll coordinates, out-of-bounds zoom, and negative selection dimensions.
  - Tests proving zero socket assigns mutation during viewport and selection broadcasts.
  - Tests proving suppression of self-generated scroll echoes.

## [0.2.0] - 2026-11-02

### Added
- **High-Performance Collaborative Cursors (Path 2: Zero Assigns Diffing)**:
  - `LiveCollab.Cursor` module for coordinate validation, bounds checking, and normalized telemetry payload creation.
  - Zero-diffing PubSub broadcast pipeline: cursor movements bypass LiveView assigns completely, dispatched via direct `push_event/3` with zero template re-renders or Morphdom diff cycles.
  - `<LiveCollab.Components.cursor_layer />` and `LiveCollab.Components.collab_cursor_attrs/2` for attaching multiplayer cursor layers to canvases, boards, or arbitrary containers.
  - Client-side hook `LiveCollabCursor`:
    - Normalized `[0.0, 1.0]` coordinates ensuring consistent cursor rendering across responsive layouts and varied screen resolutions.
    - Client-side throttled broadcast (30ms / ~33 fps) with distance deadband thresholding.
    - Smooth 60/120 FPS linear interpolation (`lerp`) via `requestAnimationFrame`.
    - Crisp SVG cursor arrow with customized username pill styled using the collaborator's deterministic color.
    - Automatic 4-second inactivity fadeout and instantaneous `pointerleave` cleanup.
    - Local cursor echo suppression (clients never re-render their own cursor).
- **Unit and Adversarial Test Suite for Cursors**:
  - Validates coordinate normalization, bounds checking, and rejection of non-numeric, NaN, or infinity payloads.
  - Verifies that LiveView assigns remain 100% untouched during high-frequency cursor telemetry bursts.
  - Verifies filtering of self-echoed cursor messages.

## [0.1.1] - 2026-11-02

### Added
- **Element & Table-Row Activity Indicators**:
  - `LiveCollab.Element` module for shared multi-user element presence extraction, sanitization, and activity queries.
  - Three activity states: `:viewing`, `:selected`, and `:editing` (automatically upgraded when a field lock is active inside the row).
  - `<LiveCollab.Components.row_indicator />` functional component for rendering compact stacked avatars and status pills on table rows.
  - `<LiveCollab.Components.element_activity />` functional component for generic cards, sections, or canvas elements.
  - `LiveCollab.Components.collab_row_attrs/4` attribute generator with dynamic CSS variable theming (`--collab-element-color`) and accessible `aria-description`.
  - Client-side hook `LiveCollabElement` supporting `click`, `focusin`, and debounced `hover_intent` to eliminate Presence diff storms on rapid cursor travel over large tables.
- **Unit and Adversarial Tests**:
  - Multi-user element concurrency tests verifying that multiple users viewing the same row coexist peacefully without race collisions.
  - Sanitization tests preventing malicious element IDs and memory attacks.
  - Rapid atomic element switching tests verifying no dangling element activity remains on row exit.

## [0.1.0] - 2026-11-01

### Added
- **Presence Tracking**: `LiveCollab.track/4` and `LiveCollab.untrack/2` with automatic lifecycle hook attachment.
- **Multi-Tab Sessions**: Client-isolated session identifiers (`client_id`) enabling transparent handling of multi-tab sessions per user.
- **Avatar Stack Component**: Functional component `<LiveCollab.Components.avatar_stack />` with customizable slots, initial generation, deterministic colors, and overflow badges.
- **Field-Level Collaboration**: Real-time focus and advisory locking with `<LiveCollab.Components.field_indicator />` and `LiveCollab.Components.collab_attrs/4`.
- **Deterministic Conflict Resolution**: Decentralized tie-breaking on `{acquired_at, client_id}` resolving concurrent claims without distributed locks.
- **Adversarial Input Validation**: Sanitization and size limits for field identifiers preventing XSS and memory exhaustion.
- **Ecto Changeset Protection**: `LiveCollab.Field.validate_not_locked/5` for server-side form submission enforcement.
- **JavaScript Hooks**: `LiveCollabField` client hook with focus debouncing, atomic field transitions, and `live_collab:lock_lost` event handling.
- **Exhaustive Test Suite**: Unit, component, and adversarial tests covering race conditions, crashes, and split-brain scenarios.
