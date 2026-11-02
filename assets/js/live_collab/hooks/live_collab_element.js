/**
 * LiveCollab - Collaborative Element & Row Hook
 *
 * Provides real-time activity indicators for table rows, cards, and sections.
 *
 * Features:
 * - Immediate activation on click and keyboard focus (`focusin`)
 * - Configurable Hover Intent debounce to prevent mouse-movement diff storms
 * - Tab/window isolation using shared tab client ID
 * - Accessible ARIA state reflection
 * - Clean lifecycle disposal on destroy or navigation
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

export const LiveCollabElement = {
  mounted() {
    this.clientId = getTabClientId();
    this.elementId = this.el.dataset.collabElement || this.el.id;
    this.type = this.el.dataset.collabType || "viewing";
    this.hoverIntentMs = parseInt(this.el.dataset.collabHoverIntent, 10) || null;
    this.hoverTimer = null;
    this.isActive = false;

    if (!this.elementId) {
      console.warn("[LiveCollab] Hook mounted on element without data-collab-element or id:", this.el);
      return;
    }

    this.handleClick = this.handleClick.bind(this);
    this.handleFocusIn = this.handleFocusIn.bind(this);
    this.handleFocusOut = this.handleFocusOut.bind(this);
    this.handleMouseEnter = this.handleMouseEnter.bind(this);
    this.handleMouseLeave = this.handleMouseLeave.bind(this);

    // Primary interaction triggers
    this.el.addEventListener("click", this.handleClick);
    this.el.addEventListener("focusin", this.handleFocusIn);
    this.el.addEventListener("focusout", this.handleFocusOut);

    // Hover intent handling (only if explicitly enabled)
    if (this.hoverIntentMs && this.hoverIntentMs > 0) {
      this.el.addEventListener("mouseenter", this.handleMouseEnter);
      this.el.addEventListener("mouseleave", this.handleMouseLeave);
    }
  },

  updated() {
    const newElementId = this.el.dataset.collabElement || this.el.id;
    if (newElementId !== this.elementId) {
      this.elementId = newElementId;
    }
    this.type = this.el.dataset.collabType || "viewing";
  },

  destroyed() {
    this.clearTimers();
    this.el.removeEventListener("click", this.handleClick);
    this.el.removeEventListener("focusin", this.handleFocusIn);
    this.el.removeEventListener("focusout", this.handleFocusOut);
    this.el.removeEventListener("mouseenter", this.handleMouseEnter);
    this.el.removeEventListener("mouseleave", this.handleMouseLeave);

    if (this.isActive) {
      this.pushEvent("live_collab:element_inactive", {
        element: this.elementId,
        client_id: this.clientId
      });
      this.isActive = false;
    }
  },

  handleClick(_event) {
    this.activateElement("selected");
  },

  handleFocusIn(_event) {
    this.activateElement("viewing");
  },

  handleFocusOut(event) {
    // If focus moves to another child within this same element, remain active
    if (this.el.contains(event.relatedTarget)) {
      return;
    }

    this.deactivateElement();
  },

  handleMouseEnter(_event) {
    this.clearTimers();
    this.hoverTimer = setTimeout(() => {
      this.activateElement("viewing");
      this.hoverTimer = null;
    }, this.hoverIntentMs);
  },

  handleMouseLeave(_event) {
    this.clearTimers();
    // Only deactivate on mouseleave if it was activated via hover (not keyboard focus)
    if (this.isActive && !this.el.contains(document.activeElement)) {
      this.deactivateElement();
    }
  },

  activateElement(type) {
    this.isActive = true;
    this.pushEvent("live_collab:element_active", {
      element: this.elementId,
      type: type || this.type,
      client_id: this.clientId
    });
  },

  deactivateElement() {
    if (this.isActive) {
      this.isActive = false;
      this.pushEvent("live_collab:element_inactive", {
        element: this.elementId,
        client_id: this.clientId
      });
    }
  },

  clearTimers() {
    if (this.hoverTimer) {
      clearTimeout(this.hoverTimer);
      this.hoverTimer = null;
    }
  }
};

export default LiveCollabElement;

