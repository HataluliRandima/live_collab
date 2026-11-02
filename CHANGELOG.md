# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
