/**
 * LiveCollab - Collaborative Field Hook
 *
 * Provides real-time field-level presence and advisory locking for form inputs.
 *
 * Capabilities:
 * - Focus/blur lifecycle tracking with atomic field transitions (no focus/blur flicker)
 * - Deterministic conflict handling (reacts to `live_collab:lock_lost` from server)
 * - Accessible ARIA state management (`aria-readonly`, `aria-describedby`)
 * - Tab/Window isolation using unique tab-session client UUIDs
 * - Graceful cleanup on hook destroy / navigation
 */

// Generate or retrieve persistent tab-level client identifier (isolated per browser tab)
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
    // Fallback if sessionStorage is blocked
    return "tab_" + Math.random().toString(36).substring(2, 15) + Date.now().toString(36);
  }
}

export const LiveCollabField = {
  mounted() {
    this.clientId = getTabClientId();
    this.fieldId = this.el.dataset.collabField || this.el.name || this.el.id;
    this.blurTimer = null;
    this.isLockedByOther = false;

    if (!this.fieldId) {
      console.warn("[LiveCollab] Hook mounted on input without data-collab-field, name, or id attribute:", this.el);
      return;
    }

    // Attach event listeners
    this.handleFocus = this.handleFocus.bind(this);
    this.handleBlur = this.handleBlur.bind(this);

    this.el.addEventListener("focus", this.handleFocus);
    this.el.addEventListener("blur", this.handleBlur);

    // Handle server-directed lock loss (e.g. lost deterministic tie-break or split-brain resolution)
    this.handleLockLost = ({ field, locked_by }) => {
      if (field === this.fieldId) {
        this.el.blur();
        this.el.setAttribute("readonly", "readonly");
        this.el.setAttribute("aria-readonly", "true");
        this.el.classList.add("collab-locked", "collab-lock-lost-pulse");

        // Dispatch a custom DOM event so the application UI can show an inline notification or toast
        this.el.dispatchEvent(new CustomEvent("live_collab:conflict", {
          bubbles: true,
          detail: { field, locked_by }
        }));
      }
    };

    this.handleEvent(`live_collab:lock_lost:${this.fieldId}`, this.handleLockLost);
    this.handleEvent("live_collab:lock_lost", this.handleLockLost);

    // Initial state check from DOM attributes
    this.syncLockState();
  },

  updated() {
    // Re-sync fieldId in case dynamic form re-rendered
    const newFieldId = this.el.dataset.collabField || this.el.name || this.el.id;
    if (newFieldId !== this.fieldId) {
      this.fieldId = newFieldId;
    }
    this.syncLockState();
  },

  destroyed() {
    if (this.blurTimer) {
      clearTimeout(this.blurTimer);
      this.blurTimer = null;
    }

    this.el.removeEventListener("focus", this.handleFocus);
    this.el.removeEventListener("blur", this.handleBlur);

    // Release lock on unmount if we were actively focused
    if (document.activeElement === this.el) {
      this.pushEvent("live_collab:field_blur", {
        field: this.fieldId,
        client_id: this.clientId
      });
    }
  },

  handleFocus(_event) {
    // Cancel any pending blur timer from rapid field switching
    if (this.blurTimer) {
      clearTimeout(this.blurTimer);
      this.blurTimer = null;
    }

    // If another user already locks this field, do not attempt to lock
    if (this.isLockedByOther) {
      return;
    }

    // Send focus event to LiveView
    this.pushEvent("live_collab:field_focus", {
      field: this.fieldId,
      client_id: this.clientId
    });
  },

  handleBlur(_event) {
    // Debounce blur by 80ms to avoid lock flapping when tabbing between inputs
    // or when focus shifts momentarily within the document
    if (this.blurTimer) {
      clearTimeout(this.blurTimer);
    }

    this.blurTimer = setTimeout(() => {
      this.pushEvent("live_collab:field_blur", {
        field: this.fieldId,
        client_id: this.clientId
      });
      this.blurTimer = null;
    }, 80);
  },

  syncLockState() {
    const isLockedAttr = this.el.dataset.collabLocked === "true";
    const lockedByClient = this.el.dataset.collabLockedByClient;

    // It is locked by someone else if marked locked and not by our own tab client ID
    this.isLockedByOther = isLockedAttr && lockedByClient !== this.clientId;

    if (this.isLockedByOther) {
      if (this.el.dataset.collabReadonly !== "false") {
        this.el.setAttribute("readonly", "readonly");
      }
      this.el.setAttribute("aria-readonly", "true");
      this.el.classList.add("collab-locked");
    } else {
      // Only remove readonly if it was added for collaboration locking
      if (this.el.dataset.collabReadonly !== "false" && this.el.hasAttribute("readonly") && !this.el.dataset.defaultReadonly) {
        this.el.removeAttribute("readonly");
      }
      this.el.removeAttribute("aria-readonly");
      this.el.classList.remove("collab-locked");
    }
  }
};

export default LiveCollabField;
