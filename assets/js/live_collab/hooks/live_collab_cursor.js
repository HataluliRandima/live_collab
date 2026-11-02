/**
 * LiveCollab - Collaborative Cursors Hook
 *
 * Provides high-performance, butter-smooth multiplayer cursors via:
 * - Normalized container coordinates [0.0, 1.0] ensuring alignment across all display resolutions
 * - Client-side throttled broadcast (30ms / ~33 fps) with distance deadband
 * - Client-side requestAnimationFrame interpolation (smooth 60/120fps rendering)
 * - Zero LiveView assigns diffing or server DOM reconciliation
 * - Accessible, hardware-accelerated SVG pointers with customizable user name pills
 */

function getTabClientId() {
  const KEY = "live_collab_tab_id";
  try {
    let id = window.sessionStorage.getItem(KEY);
    if (!id) {
      id = typeof crypto !== "undefined" && crypto.randomUUID
        ? crypto.randomUUID()
        : "tab_" + Math.random().toString(36).substring(2, 15) + Date.now().toString(36);
      window.sessionStorage.setItem(KEY, id);
    }
    return id;
  } catch (_e) {
    return "tab_" + Math.random().toString(36).substring(2, 15) + Date.now().toString(36);
  }
}

export const LiveCollabCursor = {
  mounted() {
    this.clientId = getTabClientId();
    this.containerId = this.el.dataset.collabContainer || "default";
    this.throttleMs = parseInt(this.el.dataset.collabThrottle, 10) || 30;
    this.deadband = parseFloat(this.el.dataset.collabDeadband) || 0.0015;

    this.lastSentAt = 0;
    this.lastSentX = -1;
    this.lastSentY = -1;

    // Remote cursors state map: { client_id => { el, currentX, currentY, targetX, targetY, fadeTimer } }
    this.remoteCursors = new Map();
    this.animationFrameId = null;

    // Ensure container has relative/absolute positioning so overlay aligns perfectly
    const computedStyle = window.getComputedStyle(this.el);
    if (computedStyle.position === "static") {
      this.el.style.position = "relative";
    }

    // Create the pointer-events-none cursor layer
    this.cursorLayer = document.createElement("div");
    this.cursorLayer.className = "live-collab-cursor-layer pointer-events-none absolute inset-0 overflow-hidden z-50 select-none";
    this.el.appendChild(this.cursorLayer);

    // Event listeners
    this.handlePointerMove = this.handlePointerMove.bind(this);
    this.handlePointerLeave = this.handlePointerLeave.bind(this);
    this.renderLoop = this.renderLoop.bind(this);

    this.el.addEventListener("pointermove", this.handlePointerMove);
    this.el.addEventListener("pointerleave", this.handlePointerLeave);

    // Handle remote cursor messages pushed from server (zero assigns diffing)
    this.handleCursorMoved = (payload) => {
      if (payload.client_id === this.clientId) return;
      if (payload.container_id && payload.container_id !== this.containerId) return;

      this.updateRemoteCursor(payload);
    };

    this.handleCursorLeft = (payload) => {
      if (payload.client_id === this.clientId) return;
      this.removeRemoteCursor(payload.client_id);
    };

    this.handleEvent("live_collab:cursor_moved", this.handleCursorMoved);
    this.handleEvent("live_collab:cursor_left", this.handleCursorLeft);

    // Start RAF interpolation render loop
    this.animationFrameId = requestAnimationFrame(this.renderLoop);
  },

  destroyed() {
    if (this.animationFrameId) {
      cancelAnimationFrame(this.animationFrameId);
      this.animationFrameId = null;
    }

    this.el.removeEventListener("pointermove", this.handlePointerMove);
    this.el.removeEventListener("pointerleave", this.handlePointerLeave);

    // Clean up all remote cursor DOM nodes and timers
    this.remoteCursors.forEach((cursor) => {
      if (cursor.fadeTimer) clearTimeout(cursor.fadeTimer);
      if (cursor.el && cursor.el.parentNode) cursor.el.remove();
    });
    this.remoteCursors.clear();

    if (this.cursorLayer && this.cursorLayer.parentNode) {
      this.cursorLayer.remove();
    }

    // Notify peers that local cursor left
    this.pushEvent("live_collab:cursor_left", {
      container_id: this.containerId,
      client_id: this.clientId
    });
  },

  handlePointerMove(event) {
    const now = performance.now();
    if (now - this.lastSentAt < this.throttleMs) return;

    const rect = this.el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;

    // Calculate normalized container coordinates [0.0, 1.0]
    const normX = (event.clientX - rect.left) / rect.width;
    const normY = (event.clientY - rect.top) / rect.height;

    // Check distance deadband to avoid transmitting micro-tremors
    const dx = normX - this.lastSentX;
    const dy = normY - this.lastSentY;
    if (Math.sqrt(dx * dx + dy * dy) < this.deadband) return;

    this.lastSentAt = now;
    this.lastSentX = normX;
    this.lastSentY = normY;

    this.pushEvent("live_collab:cursor_move", {
      x: normX,
      y: normY,
      container_id: this.containerId,
      client_id: this.clientId
    });
  },

  handlePointerLeave(_event) {
    this.pushEvent("live_collab:cursor_left", {
      container_id: this.containerId,
      client_id: this.clientId
    });
  },

  updateRemoteCursor(payload) {
    const { client_id, user_name, user_color, x, y } = payload;
    let cursor = this.remoteCursors.get(client_id);

    if (!cursor) {
      // Create new cursor DOM element
      const el = document.createElement("div");
      el.className = "live-collab-remote-cursor absolute top-0 left-0 transition-opacity duration-200";
      el.style.opacity = "1";
      el.style.willChange = "transform";

      const color = user_color || "#4F46E5";
      const name = user_name || "Collaborator";

      // SVG arrow pointer + name pill
      el.innerHTML = `
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" class="filter drop-shadow" style="transform: rotate(0deg);">
          <path d="M5.65376 12.3673H5.46026L5.31717 12.4976L0.500002 16.8829L0.500002 1.19841L11.7841 12.3673H5.65376Z" fill="${color}" stroke="#FFFFFF" stroke-width="1.2"/>
        </svg>
        <div class="live-collab-cursor-pill inline-block px-1.5 py-0.5 rounded text-[11px] font-semibold text-white whitespace-nowrap shadow-sm ml-3.5 -mt-2" style="background-color: ${color};">
          ${name}
        </div>
      `;

      this.cursorLayer.appendChild(el);

      cursor = {
        el,
        currentX: x,
        currentY: y,
        targetX: x,
        targetY: y,
        fadeTimer: null
      };

      this.remoteCursors.set(client_id, cursor);
    } else {
      cursor.targetX = x;
      cursor.targetY = y;
      cursor.el.style.opacity = "1";
    }

    // Reset 4-second inactivity fadeout timer
    if (cursor.fadeTimer) clearTimeout(cursor.fadeTimer);
    cursor.fadeTimer = setTimeout(() => {
      if (cursor.el) cursor.el.style.opacity = "0";
    }, 4000);
  },

  removeRemoteCursor(clientId) {
    const cursor = this.remoteCursors.get(clientId);
    if (cursor) {
      if (cursor.fadeTimer) clearTimeout(cursor.fadeTimer);
      if (cursor.el) cursor.el.remove();
      this.remoteCursors.delete(clientId);
    }
  },

  renderLoop() {
    const rect = this.el.getBoundingClientRect();
    const width = rect.width;
    const height = rect.height;

    if (width > 0 && height > 0) {
      this.remoteCursors.forEach((cursor) => {
        // Linear interpolation (lerp) for buttery 60fps smoothing
        cursor.currentX += (cursor.targetX - cursor.currentX) * 0.35;
        cursor.currentY += (cursor.targetY - cursor.currentY) * 0.35;

        const pixelX = cursor.currentX * width;
        const pixelY = cursor.currentY * height;

        cursor.el.style.transform = `translate3d(${pixelX}px, ${pixelY}px, 0)`;
      });
    }

    this.animationFrameId = requestAnimationFrame(this.renderLoop);
  }
};

export default LiveCollabCursor;

