/**
 * LiveCollab - Multiplayer Selection Containers Hook
 *
 * Renders real-time collaborative selection bounding boxes and marquee rectangles.
 *
 * Capabilities:
 * - Normalized coordinate bounding box mapping [0.0, 1.0]
 * - Visual collaborator indicators: border & translucent fill in user's color + username tag
 * - Automatic fadeout and leave cleanup
 * - Zero LiveView assigns diffing
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

export const LiveCollabSelection = {
  mounted() {
    this.clientId = getTabClientId();
    this.containerId = this.el.dataset.collabContainer || "default";
    this.remoteSelections = new Map();

    // Ensure relative positioning
    const computed = window.getComputedStyle(this.el);
    if (computed.position === "static") {
      this.el.style.position = "relative";
    }

    // Selection overlay layer
    this.selectionLayer = document.createElement("div");
    this.selectionLayer.className = "live-collab-selection-layer pointer-events-none absolute inset-0 overflow-hidden z-40 select-none";
    this.el.appendChild(this.selectionLayer);

    this.handleSelectionMoved = this.handleSelectionMoved.bind(this);
    this.handleSelectionCleared = this.handleSelectionCleared.bind(this);

    this.handleEvent("live_collab:selection_moved", this.handleSelectionMoved);
    this.handleEvent("live_collab:selection_cleared", this.handleSelectionCleared);
  },

  destroyed() {
    this.remoteSelections.forEach((item) => {
      if (item.fadeTimer) clearTimeout(item.fadeTimer);
      if (item.el && item.el.parentNode) item.el.remove();
    });
    this.remoteSelections.clear();

    if (this.selectionLayer && this.selectionLayer.parentNode) {
      this.selectionLayer.remove();
    }
  },

  handleSelectionMoved(payload) {
    if (payload.client_id === this.clientId) return;
    if (payload.container_id && payload.container_id !== this.containerId) return;

    const rect = this.el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;

    // Convert normalized coordinates to container pixels
    const pxX = payload.x * rect.width;
    const pxY = payload.y * rect.height;
    const pxW = payload.width * rect.width;
    const pxH = payload.height * rect.height;

    let selection = this.remoteSelections.get(payload.client_id);
    const color = payload.user_color || "#4F46E5";
    const name = payload.user_name || "Collaborator";

    if (!selection) {
      const el = document.createElement("div");
      el.className = "live-collab-selection-box absolute transition-all duration-75 pointer-events-none";
      el.style.border = `2px solid ${color}`;
      el.style.backgroundColor = `${color}1A`; // ~10-15% opacity hex
      el.style.borderRadius = "4px";

      const tag = document.createElement("div");
      tag.className = "live-collab-selection-tag absolute -top-5 left-0 px-1.5 py-0.5 rounded text-[10px] font-bold text-white whitespace-nowrap shadow-sm";
      tag.style.backgroundColor = color;
      tag.textContent = `${name}'s selection`;

      el.appendChild(tag);
      this.selectionLayer.appendChild(el);

      selection = { el, fadeTimer: null };
      this.remoteSelections.set(payload.client_id, selection);
    }

    // Update dimensions
    selection.el.style.transform = `translate3d(${pxX}px, ${pxY}px, 0)`;
    selection.el.style.width = `${pxW}px`;
    selection.el.style.height = `${pxH}px`;
    selection.el.style.opacity = "1";

    // Auto-fade after 5 seconds of inactivity
    if (selection.fadeTimer) clearTimeout(selection.fadeTimer);
    selection.fadeTimer = setTimeout(() => {
      if (selection.el) selection.el.style.opacity = "0";
    }, 5000);
  },

  handleSelectionCleared(payload) {
    if (payload.client_id === this.clientId) return;

    const selection = this.remoteSelections.get(payload.client_id);
    if (selection) {
      if (selection.fadeTimer) clearTimeout(selection.fadeTimer);
      if (selection.el) selection.el.remove();
      this.remoteSelections.delete(payload.client_id);
    }
  }
};

export default LiveCollabSelection;

