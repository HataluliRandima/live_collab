# Contributing to LiveCollab

Thanks for helping! This guide covers the development setup and what a good pull
request looks like.

## Setup

Requirements: Elixir 1.15+ / OTP 26+, Node.js 22+ (for the JS hook tests), and
`epmd` for the multi-node tests (it ships with Erlang).

```bash
git clone https://github.com/HataluliRandima/live_collab.git
cd live_collab
mix deps.get
npm ci
```

## Running the checks

```bash
mix test                              # unit + LiveView integration tests (real Presence/PubSub)
epmd -daemon && mix test --only distributed   # multi-node tests using :peer
npm test                              # JS hook tests (node:test + jsdom)
mix format --check-formatted
mix credo --strict
mix dialyzer
mix hex.audit
```

`mix ci` runs format, compile (warnings as errors), credo and tests in one go.

Benchmarks are not part of CI:

```bash
mix run bench/presence_rebuild.exs                                  # Benchee microbenchmark
BENCH_SIZES=10,100,500 mix test test/bench --include benchmark      # end-to-end room benchmark
```

## Test layout

| Path | What it covers |
| :--- | :--- |
| `test/live_collab/` | Pure modules (validation, rate limiter, conflict resolution, components) |
| `test/integration/` | Real LiveViews (`Phoenix.LiveViewTest`) against a real `Phoenix.Presence` |
| `test/distributed/` | Multiple BEAM nodes: replication, partitions, node failure (`:distributed` tag) |
| `test/bench/` | End-to-end room benchmark (`:benchmark` tag) |
| `assets/test/` | JS hooks under jsdom |

Guidelines:

- **Test against the real thing.** Integration tests use a real
  `Phoenix.Presence`. A mock that accepted a LiveView socket instead of a pid once
  hid a crash affecting every user.
- **No fixed sleeps.** Presence is eventually consistent; use
  `LiveCollab.CollabCase.eventually/2`, `assert_push_event/3` or
  `assert_receive`.
- **Bug fixes need a regression test**, ideally one that fails without the fix.
- **Async tests share telemetry handlers**; use `capture_telemetry(view, events)`,
  which filters by the view's client id.

## Design principles

- Client input is untrusted, always. Validate in `LiveCollab.Validation`, never
  take identity from params, and render other users' data with `textContent`.
- High-frequency events must not touch assigns. Per-socket state that changes
  per event belongs in `socket.private`.
- Every Presence write is replicated cluster-wide and triggers a rebuild in every
  collaborator, so avoid redundant writes.
- Don't overstate guarantees. If a behaviour is best-effort, the docs say so (see
  `guides/guarantees.md`).

## Pull requests

- Keep changes focused; one topic per PR.
- Add an entry under `## [Unreleased]` in `CHANGELOG.md`.
- Document public API changes (`@doc`, `@spec`, README/guides).
- Call out breaking changes explicitly.

By contributing you agree that your contributions are licensed under the MIT
License and that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
