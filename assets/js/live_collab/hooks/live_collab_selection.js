/**
 * LiveCollab - Multiplayer Selection Containers Hook
 *
 * Renders collaborators' selection boxes (normalized [0.0, 1.0] coordinates) in
 * their color with a name tag, and forwards *your* selection to the server.
 *
 * Reporting the local selection: dispatch a DOM event on (or inside) the
 * container from your own selection logic:
 *
 *     container.dispatchEvent(new CustomEvent("live_collab:local_selection", {
 *       bubbles: true,
 *       detail: { x: 0.1, y: 0.2, width: 0.3, height: 0.1, selected_ids: ["card-1"] }
 *     }))
 *
 *     container.dispatchEvent(new CustomEvent("live_collab:local_selection_clear", { bubbles: true }))
 *
 * Reports are throttled (`data-collab-throttle`, default 50ms; the latest
 * selection is always delivered). Remote boxes fade after inactivity, are removed
 * from the DOM shortly after, and immediately when the collaborator leaves.
 *
 * Security: names are written with textContent and colors must be #rrggbb.
 */

import {
  adoptLayer,
  departedClientIds,
  ensureLayerAttached,
  finite,
  matchesContainer,
  safeColor,
  safeName,
  safePush
} from "../utils.js";

export const LiveCollabSelection = {
  mounted() {
    this.containerId = this.el.dataset.collabContainer || "default";
    this.throttleMs = parseInt(this.el.dataset.collabThrottle, 10) || 50;
    this.fadeMs = parseInt(this.el.dataset.collabFadeMs, 10) || 5000;
    this.removeMs = this.fadeMs + 1000;
    this.remoteSelections = new Map();
    this.lastSentAt = 0;
    this.pendingSelection = null;
    this.trailingTimer = null;

    if (window.getComputedStyle(this.el).position === "static") {
      this.el.style.position = "relative";
    }

    const { layer, owned } = adoptLayer(this.el, "live-collab-selection-layer z-40");
    this.selectionLayer = layer;
    this.ownsLayer = owned;

    this.handleLocalSelection = this.handleLocalSelection.bind(this);
    this.handleLocalClear = this.handleLocalClear.bind(this);
    this.el.addEventListener("live_collab:local_selection", this.handleLocalSelection);
    this.el.addEventListener("live_collab:local_selection_clear", this.handleLocalClear);

    this.handleEvent("live_collab:selection_moved", (payload) => {
      if (matchesContainer(payload, this.containerId)) this.updateRemoteSelection(payload);
    });

    this.handleEvent("live_collab:selection_cleared", (payload) => {
      if (matchesContainer(payload, this.containerId)) this.removeRemoteSelection(payload.client_id);
    });

    this.handleEvent("live_collab:peers_left", (payload) => {
      departedClientIds(payload).forEach((id) => this.removeRemoteSelection(id));
    });
  },

  updated() {
    if (this.ownsLayer) ensureLayerAttached(this.el, this.selectionLayer);
  },

  destroyed() {
    clearTimeout(this.trailingTimer);
    this.el.removeEventListener("live_collab:local_selection", this.handleLocalSelection);
    this.el.removeEventListener("live_collab:local_selection_clear", this.handleLocalClear);
    this.remoteSelections.forEach((_item, clientId) => this.removeRemoteSelection(clientId));
    if (this.ownsLayer && this.selectionLayer) this.selectionLayer.remove();
  },

  // --- local selection -> server ------------------------------------------------

  handleLocalSelection(event) {
    const d = (event && event.detail) || {};
    const box = [finite(d.x), finite(d.y), finite(d.width), finite(d.height)];
    if (box.includes(null)) return;

    this.pendingSelection = {
      x: box[0],
      y: box[1],
      width: box[2],
      height: box[3],
      selected_ids: Array.isArray(d.selected_ids) ? d.selected_ids.slice(0, 100) : [],
      container_id: this.containerId
    };
    this.flushSelection();
  },

  flushSelection() {
    const wait = this.throttleMs - (performance.now() - this.lastSentAt);

    if (wait <= 0) {
      clearTimeout(this.trailingTimer);
      this.trailingTimer = null;
      this.lastSentAt = performance.now();
      const payload = this.pendingSelection;
      this.pendingSelection = null;
      if (payload) safePush(this, "live_collab:selection_move", payload);
    } else if (!this.trailingTimer) {
      // Trailing edge: the final selection of a drag is never dropped.
      this.trailingTimer = setTimeout(() => {
        this.trailingTimer = null;
        this.flushSelection();
      }, wait);
    }
  },

  handleLocalClear(_event) {
    clearTimeout(this.trailingTimer);
    this.trailingTimer = null;
    this.pendingSelection = null;
    safePush(this, "live_collab:selection_clear", { container_id: this.containerId });
  },

  // --- remote selections ----------------------------------------------------------

  updateRemoteSelection(payload) {
    const clientId = payload && payload.client_id;
    const box = [finite(payload.x), finite(payload.y), finite(payload.width), finite(payload.height)];
    if (typeof clientId !== "string" || box.includes(null)) return;

    const rect = this.el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;

    let selection = this.remoteSelections.get(clientId);

    if (!selection) {
      const color = safeColor(payload.user_color);
      const el = document.createElement("div");
      el.className = "live-collab-selection-box absolute top-0 left-0 transition-all duration-75 pointer-events-none";
      el.style.border = `2px solid ${color}`;
      el.style.backgroundColor = `${color}1A`;
      el.style.borderRadius = "4px";
      el.style.position = "absolute";
      el.style.top = "0";
      el.style.left = "0";

      const tag = document.createElement("div");
      tag.className =
        "live-collab-selection-tag absolute -top-5 left-0 px-1.5 py-0.5 rounded text-[10px] font-bold text-white whitespace-nowrap shadow-sm";
      tag.style.backgroundColor = color;
      tag.style.color = "#fff";
      tag.style.position = "absolute";
      tag.style.top = "-20px";
      tag.style.left = "0";
      tag.textContent = `${safeName(payload.user_name)}'s selection`;

      el.appendChild(tag);
      this.selectionLayer.appendChild(el);
      selection = { el, fadeTimer: null, removeTimer: null };
      this.remoteSelections.set(clientId, selection);
    }

    const [x, y, width, height] = box;
    selection.el.style.transform = `translate3d(${x * rect.width}px, ${y * rect.height}px, 0)`;
    selection.el.style.width = `${width * rect.width}px`;
    selection.el.style.height = `${height * rect.height}px`;
    selection.el.style.opacity = "1";

    clearTimeout(selection.fadeTimer);
    clearTimeout(selection.removeTimer);
    selection.fadeTimer = setTimeout(() => {
      selection.el.style.opacity = "0";
    }, this.fadeMs);
    selection.removeTimer = setTimeout(() => this.removeRemoteSelection(clientId), this.removeMs);
  },

  removeRemoteSelection(clientId) {
    const selection = this.remoteSelections.get(clientId);
    if (!selection) return;
    clearTimeout(selection.fadeTimer);
    clearTimeout(selection.removeTimer);
    selection.el.remove();
    this.remoteSelections.delete(clientId);
  }
};

export default LiveCollabSelection;
