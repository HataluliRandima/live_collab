# Consistency guarantees

LiveCollab is built on `Phoenix.Presence` (an eventually consistent CRDT
replicated by `Phoenix.Tracker`) and `Phoenix.PubSub`. This page states what that
combination does and does not guarantee, so you can decide where LiveCollab's
state is safe to rely on.

## Summary

| Property | Guarantee |
| :--- | :--- |
| Presence (who is here) | Eventually consistent across the cluster. Local changes are visible to local LiveViews within milliseconds; remote nodes converge after the Tracker's broadcast period (default 1.5 s). |
| Field locks | **Advisory.** Every node computes the same winner once Presence has converged. Two clients can both believe they hold a lock until then. |
| Lock ordering | Deterministic, not fair. Ordered by `{acquired_at window, client_id}` using the wall clock of the node hosting each LiveView. |
| Cursor / viewport / selection events | Best effort, at most once, no ordering guarantee across senders. Dropped under rate limiting. Never persisted. |
| Spotlight (presenter mode) | Best effort, held in each LiveView's memory. Clients that join after the presentation started are not told about it. |
| Cleanup on disconnect | Automatic. Presence untracks a LiveView when its process exits; on node failure, after the Tracker's `down_period`. |

## Field locks are advisory

A lock is a claim written into the claiming LiveView's own Presence metadata. There
is no coordinator and no consensus round. When two clients claim the same field
concurrently (for example on two nodes, or on both sides of a network partition),
each node first sees only its local claim. When the claims replicate, every node
evaluates `LiveCollab.Field.resolve_conflict/2`, a pure function of the claims,
and reaches the same winner. The loser's LiveView pushes `live_collab:lock_lost`
and its input becomes read-only.

What this means in practice:

* Treat locks as a **UX coordination aid**. They prevent most accidental
  overwrites and show who is editing what.
* **Do not** rely on them for data integrity. Validate on submit with
  `LiveCollab.validate_not_locked/5`, and use optimistic concurrency (e.g. Ecto
  `:lock_version`) for anything that must not be lost.
* During a partition, both sides can grant the same lock. After the partition
  heals, all nodes converge on one winner. This is covered by
  `test/distributed/cluster_test.exs`.

## Ordering and clock skew

Claims are ordered by `div(acquired_at, clock_skew_tolerance_ms)`, then by
`client_id`. `acquired_at` is taken from `System.system_time/1` on the node that
hosts the claiming LiveView.

* With synchronised clocks, an earlier claim wins unless both claims fall in the
  same window. In the same window, the lexicographically smaller `client_id` wins.
  Client ids are random, so this tie-break is effectively a fair coin.
* With clock skew larger than the window, "earlier" reflects the skewed clocks.
  The outcome is still deterministic and identical on every node, but it may not
  match real time.
* Windows are fixed buckets, so two claims 2 ms apart can straddle a boundary, in
  which case time decides.

Before 0.5.0, the comparison also read the local clock, which could make nodes
disagree. It is now a pure function of the claims.

## Ephemeral events

Cursor, viewport, selection and spotlight messages are rebroadcast with
`Phoenix.PubSub.broadcast_from/4` and pushed to browsers with `push_event/3`.
They are not acknowledged, retried or ordered across senders. They are dropped
when the sender exceeds its token bucket. Within one sender and one receiver,
messages arrive in order (BEAM per-pair ordering) unless one of them is dropped.

## Lifecycle

* Presence entries and PubSub subscriptions belong to the LiveView process, so
  they are removed when it exits, whether normally, by crash or by
  `Process.exit/2`. No `terminate/2` is needed.
* When a collaborator leaves, peers receive `live_collab:peers_left`, and the
  bundled hooks remove that collaborator's cursor and selection immediately.
* Collaboration state is rebuilt from Presence on change. A burst of changes is
  folded into at most one rebuild per `presence_sync_interval_ms` per LiveView.
