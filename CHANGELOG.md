# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
