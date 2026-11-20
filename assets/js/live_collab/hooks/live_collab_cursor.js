/**
 * LiveCollab - Collaborative Cursors Hook
 *
 * - Normalized container coordinates [0.0, 1.0], so cursors align across screen sizes
 * - Throttled broadcast (default 30ms) with a distance deadband
 * - requestAnimationFrame interpolation that runs only while cursors are moving
 * - No LiveView re-renders: positions arrive via push_event and are drawn here
 * - Remote cursors fade after inactivity and are removed from the DOM shortly after,
 *   and immediately when the collaborator leaves (`live_collab:peers_left`)
 *
 * Security: remote names and colors come from other users. Names are written
 * with textContent only and colors must be #rrggbb, so no markup or CSS can be
 * injected into this page.
 */

import { departedClientIds, finite, matchesContainer, safeColor, safeName, safePush } from "../utils.js";

const SVG_NS = "http://www.w3.org/2000/svg";
const POINTER_PATH = "M5.65376 12.3673H5.46026L5.31717 12.4976L0.500002 16.8829L0.500002 1.19841L11.7841 12.3673H5.65376Z";
const LERP = 0.35;
const SETTLE_EPSILON = 0.0005;

export const LiveCollabCursor = {
  mounted() {
    this.containerId = this.el.dataset.collabContainer || "default";
    this.throttleMs = parseInt(this.el.dataset.collabThrottle, 10) || 30;
    this.deadband = parseFloat(this.el.dataset.collabDeadband) || 0.0015;
    this.fadeMs = parseInt(this.el.dataset.collabFadeMs, 10) || 4000;
    this.removeMs = this.fadeMs + 1000;

    this.lastSentAt = 0;
    this.lastSentX = -1;
    this.lastSentY = -1;
    this.remoteCursors = new Map();
    this.animationFrameId = null;

    if (window.getComputedStyle(this.el).position === "static") {
      this.el.style.position = "relative";
    }

    this.cursorLayer = document.createElement("div");
    this.cursorLayer.className =
      "live-collab-cursor-layer pointer-events-none absolute inset-0 overflow-hidden z-50 select-none";
    this.cursorLayer.setAttribute("aria-hidden", "true");
    this.el.appendChild(this.cursorLayer);

    this.handlePointerMove = this.handlePointerMove.bind(this);
    this.handlePointerLeave = this.handlePointerLeave.bind(this);
    this.renderLoop = this.renderLoop.bind(this);

    this.el.addEventListener("pointermove", this.handlePointerMove);
    this.el.addEventListener("pointerleave", this.handlePointerLeave);

    this.handleEvent("live_collab:cursor_moved", (payload) => {
      if (matchesContainer(payload, this.containerId)) this.updateRemoteCursor(payload);
    });

    this.handleEvent("live_collab:cursor_left", (payload) => {
      if (matchesContainer(payload, this.containerId)) this.removeRemoteCursor(payload.client_id);
    });

    this.handleEvent("live_collab:peers_left", (payload) => {
      departedClientIds(payload).forEach((id) => this.removeRemoteCursor(id));
    });
  },

  destroyed() {
    this.stopLoop();
    this.el.removeEventListener("pointermove", this.handlePointerMove);
    this.el.removeEventListener("pointerleave", this.handlePointerLeave);

    this.remoteCursors.forEach((_cursor, clientId) => this.removeRemoteCursor(clientId));
    if (this.cursorLayer) this.cursorLayer.remove();

    safePush(this, "live_collab:cursor_left", { container_id: this.containerId });
  },

  handlePointerMove(event) {
    const now = performance.now();
    if (now - this.lastSentAt < this.throttleMs) return;

    const rect = this.el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;

    const normX = (event.clientX - rect.left) / rect.width;
    const normY = (event.clientY - rect.top) / rect.height;

    const dx = normX - this.lastSentX;
    const dy = normY - this.lastSentY;
    if (Math.sqrt(dx * dx + dy * dy) < this.deadband) return;

    this.lastSentAt = now;
    this.lastSentX = normX;
    this.lastSentY = normY;

    safePush(this, "live_collab:cursor_move", { x: normX, y: normY, container_id: this.containerId });
  },

  handlePointerLeave(_event) {
    this.lastSentX = -1;
    this.lastSentY = -1;
    safePush(this, "live_collab:cursor_left", { container_id: this.containerId });
  },

  buildCursorElement(name, color) {
    const el = document.createElement("div");
    el.className = "live-collab-remote-cursor absolute top-0 left-0 transition-opacity duration-200";
    el.style.willChange = "transform";

    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("width", "22");
    svg.setAttribute("height", "22");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");

    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("d", POINTER_PATH);
    path.setAttribute("fill", color);
    path.setAttribute("stroke", "#FFFFFF");
    path.setAttribute("stroke-width", "1.2");
    svg.appendChild(path);

    const pill = document.createElement("div");
    pill.className =
      "live-collab-cursor-pill inline-block px-1.5 py-0.5 rounded text-[11px] font-semibold text-white whitespace-nowrap shadow-sm ml-3.5 -mt-2";
    pill.style.backgroundColor = color;
    pill.textContent = name;

    el.appendChild(svg);
    el.appendChild(pill);
    return el;
  },

  updateRemoteCursor(payload) {
    const clientId = payload && payload.client_id;
    const x = finite(payload && payload.x);
    const y = finite(payload && payload.y);
    if (typeof clientId !== "string" || x === null || y === null) return;

    let cursor = this.remoteCursors.get(clientId);

    if (!cursor) {
      const el = this.buildCursorElement(safeName(payload.user_name), safeColor(payload.user_color));
      this.cursorLayer.appendChild(el);
      cursor = { el, currentX: x, currentY: y, targetX: x, targetY: y, fadeTimer: null, removeTimer: null };
      this.remoteCursors.set(clientId, cursor);
      this.positionCursor(cursor);
    } else {
      cursor.targetX = x;
      cursor.targetY = y;
    }

    cursor.el.style.opacity = "1";
    this.scheduleExpiry(clientId, cursor);
    this.startLoop();
  },

  // Fade after inactivity, then drop the node entirely so departed or idle
  // collaborators do not accumulate DOM nodes for the life of the page.
  scheduleExpiry(clientId, cursor) {
    clearTimeout(cursor.fadeTimer);
    clearTimeout(cursor.removeTimer);
    cursor.fadeTimer = setTimeout(() => {
      cursor.el.style.opacity = "0";
    }, this.fadeMs);
    cursor.removeTimer = setTimeout(() => this.removeRemoteCursor(clientId), this.removeMs);
  },

  removeRemoteCursor(clientId) {
    const cursor = this.remoteCursors.get(clientId);
    if (!cursor) return;
    clearTimeout(cursor.fadeTimer);
    clearTimeout(cursor.removeTimer);
    cursor.el.remove();
    this.remoteCursors.delete(clientId);
  },

  positionCursor(cursor, rect = this.el.getBoundingClientRect()) {
    cursor.el.style.transform = `translate3d(${cursor.currentX * rect.width}px, ${cursor.currentY * rect.height}px, 0)`;
  },

  startLoop() {
    if (this.animationFrameId === null) {
      this.animationFrameId = requestAnimationFrame(this.renderLoop);
    }
  },

  stopLoop() {
    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId);
      this.animationFrameId = null;
    }
  },

  // Runs only while at least one cursor is still moving towards its target, so
  // an idle page does no per-frame layout work.
  renderLoop() {
    this.animationFrameId = null;
    const rect = this.el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;

    let moving = false;
    this.remoteCursors.forEach((cursor) => {
      const dx = cursor.targetX - cursor.currentX;
      const dy = cursor.targetY - cursor.currentY;

      if (Math.abs(dx) < SETTLE_EPSILON && Math.abs(dy) < SETTLE_EPSILON) {
        cursor.currentX = cursor.targetX;
        cursor.currentY = cursor.targetY;
      } else {
        cursor.currentX += dx * LERP;
        cursor.currentY += dy * LERP;
        moving = true;
      }

      this.positionCursor(cursor, rect);
    });

    if (moving) this.startLoop();
  }
};

export default LiveCollabCursor;
