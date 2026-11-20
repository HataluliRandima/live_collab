/**
 * LiveCollab - Collaborative Field Hook
 *
 * Field-level presence and advisory locking for form inputs.
 *
 * - Focus claims the field; blur (debounced 80ms) releases it. The blur names
 *   the field it releases, so a late blur from the previous input never releases
 *   the input that now has focus.
 * - Lock state comes from the server-rendered `data-collab-locked` attribute,
 *   which is already computed relative to this LiveView's client.
 * - `live_collab:lock_lost` blurs the input, marks it read-only and dispatches a
 *   bubbling `live_collab:conflict` DOM event for app-level notifications.
 * - A claim is released when the hook is destroyed, including when a blur was
 *   still pending.
 */

import { safePush } from "../utils.js";

const BLUR_DEBOUNCE_MS = 80;

export const LiveCollabField = {
  mounted() {
    this.fieldId = this.readFieldId();
    this.blurTimer = null;
    this.hasClaim = false;
    this.isLockedByOther = false;

    if (!this.fieldId) {
      console.warn("[LiveCollab] LiveCollabField mounted without data-collab-field, name or id:", this.el);
      return;
    }

    this.handleFocus = this.handleFocus.bind(this);
    this.handleBlur = this.handleBlur.bind(this);
    this.el.addEventListener("focus", this.handleFocus);
    this.el.addEventListener("blur", this.handleBlur);

    // The server also pushes "live_collab:lock_lost:<field>" for backwards
    // compatibility; subscribing to both would handle every loss twice.
    this.handleEvent("live_collab:lock_lost", (payload) => this.handleLockLost(payload));

    this.syncLockState();
  },

  updated() {
    const newFieldId = this.readFieldId();
    if (newFieldId !== this.fieldId) {
      // The input was re-purposed for another field: release the old claim.
      this.releaseClaim();
      this.fieldId = newFieldId;
    }
    this.syncLockState();
  },

  destroyed() {
    if (this.handleFocus) {
      this.el.removeEventListener("focus", this.handleFocus);
      this.el.removeEventListener("blur", this.handleBlur);
    }
    this.releaseClaim();
  },

  readFieldId() {
    return this.el.dataset.collabField || this.el.name || this.el.id || null;
  },

  handleFocus(_event) {
    if (this.blurTimer) {
      clearTimeout(this.blurTimer);
      this.blurTimer = null;
    }

    if (this.isLockedByOther || this.hasClaim) return;

    if (safePush(this, "live_collab:field_focus", { field: this.fieldId })) {
      this.hasClaim = true;
    }
  },

  handleBlur(_event) {
    if (this.blurTimer) clearTimeout(this.blurTimer);

    // Debounced so focus moving momentarily (e.g. to a date picker) does not flap the lock.
    this.blurTimer = setTimeout(() => {
      this.blurTimer = null;
      this.releaseClaim();
    }, BLUR_DEBOUNCE_MS);
  },

  releaseClaim() {
    if (this.blurTimer) {
      clearTimeout(this.blurTimer);
      this.blurTimer = null;
    }

    if (this.hasClaim) {
      this.hasClaim = false;
      safePush(this, "live_collab:field_blur", { field: this.fieldId });
    }
  },

  handleLockLost(payload) {
    if (!payload || payload.field !== this.fieldId) return;

    this.hasClaim = false;
    this.isLockedByOther = true;
    if (document.activeElement === this.el) this.el.blur();
    this.applyLockedState(true);
    this.el.classList.add("collab-lock-lost-pulse");

    this.el.dispatchEvent(
      new CustomEvent("live_collab:conflict", {
        bubbles: true,
        detail: { field: payload.field, locked_by: payload.locked_by }
      })
    );
  },

  syncLockState() {
    this.isLockedByOther = this.el.dataset.collabLocked === "true";
    this.applyLockedState(this.isLockedByOther);
  },

  applyLockedState(locked) {
    const manageReadonly = this.el.dataset.collabReadonly !== "false";

    if (locked) {
      if (manageReadonly) this.el.setAttribute("readonly", "readonly");
      this.el.setAttribute("aria-readonly", "true");
      this.el.classList.add("collab-locked");
    } else {
      // Only remove readonly that LiveCollab added; data-default-readonly opts out.
      if (manageReadonly && !this.el.dataset.defaultReadonly) this.el.removeAttribute("readonly");
      this.el.removeAttribute("aria-readonly");
      this.el.classList.remove("collab-locked", "collab-lock-lost-pulse");
    }
  }
};

export default LiveCollabField;
