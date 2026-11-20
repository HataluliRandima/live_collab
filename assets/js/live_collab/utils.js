/**
 * LiveCollab - shared client utilities.
 *
 * Everything received from the server about *other* collaborators (names,
 * colors, coordinates) ultimately originates from other users, so it is treated
 * as untrusted: text is only ever written with textContent, colors are checked
 * against a strict hex pattern, and coordinates must be finite numbers.
 */

const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

export const DEFAULT_COLOR = "#4F46E5";

/** Returns `color` if it is a `#rrggbb` hex color, otherwise `fallback`. */
export function safeColor(color, fallback = DEFAULT_COLOR) {
  return typeof color === "string" && HEX_COLOR.test(color) ? color : fallback;
}

/** Returns `value` if it is a finite number, otherwise `null`. */
export function finite(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** Returns a non-empty display string (max 64 chars) or the fallback. */
export function safeName(name, fallback = "Collaborator") {
  if (typeof name !== "string" || name.trim() === "") return fallback;
  return name.length > 64 ? `${name.slice(0, 63)}…` : name;
}

/**
 * pushEvent that never throws. Hooks push events from `destroyed()` and from
 * timers, which can run after the LiveView has disconnected; LiveView raises in
 * that case and the event is meaningless anyway (the server process is gone,
 * and Presence cleans up after it).
 */
export function safePush(hook, event, payload) {
  try {
    hook.pushEvent(event, payload);
    return true;
  } catch (_error) {
    return false;
  }
}

/** True when the payload targets this hook's container (or no container). */
export function matchesContainer(payload, containerId) {
  return !payload || payload.container_id == null || payload.container_id === containerId;
}

/** Normalised client ids from a `live_collab:peers_left` payload. */
export function departedClientIds(payload) {
  return payload && Array.isArray(payload.client_ids)
    ? payload.client_ids.filter((id) => typeof id === "string")
    : [];
}
