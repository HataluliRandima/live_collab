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
 * - "Ask to edit": `live_collab:lock_granted` (the holder handed over) focuses
 *   the input, which claims it.
 * - Conflict-aware forms: `live_collab:field_changed` (someone saved this field)
 *   updates an input you are not editing and highlights it for 2 s
 *   (`collab-remote-updated`); `live_collab:field_conflict` marks an input you
 *   are editing with `collab-conflict` instead of touching your text. The
 *   `live_collab:apply_remote` DOM event (sent by "Use theirs" in
 *   `<.field_change_notice>`) puts the saved value in and fires `input`.
 *   Bubbling `live_collab:remote_change` DOM events report both cases.
 */

import { safePush } from "../utils.js";

const BLUR_DEBOUNCE_MS = 80;
const HIGHLIGHT_MS = 2000;

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
    this.handleEvent("live_collab:lock_granted", (payload) => this.handleLockGranted(payload));
    this.handleEvent("live_collab:field_changed", (payload) => this.handleRemoteChange(payload, false));
    this.handleEvent("live_collab:field_conflict", (payload) => this.handleRemoteChange(payload, true));
    this.handleEvent("live_collab:change_dismissed", (payload) => {
      if (payload && payload.field === this.fieldId) this.el.classList.remove("collab-conflict");
    });

    this.handleApplyRemote = this.handleApplyRemote.bind(this);
    this.el.addEventListener("live_collab:apply_remote", this.handleApplyRemote);
    this.highlightTimer = null;

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
      this.el.removeEventListener("live_collab:apply_remote", this.handleApplyRemote);
    }
    clearTimeout(this.highlightTimer);
    this.releaseClaim();
  },

  handleLockGranted(payload) {
    if (!payload || payload.field !== this.fieldId) return;
    // The server already dropped the previous holder's lock for this client;
    // unlock locally so the focus below is allowed to claim the field.
    this.isLockedByOther = false;
    this.applyLockedState(false);
    this.el.focus();
  },

  handleRemoteChange(payload, conflict) {
    if (!payload || payload.field !== this.fieldId) return;
    const value = payload.value == null ? "" : String(payload.value);
    const editing = conflict || document.activeElement === this.el;

    if (editing) {
      // Never overwrite text the user is typing; <.field_change_notice> offers the choice.
      this.el.classList.add("collab-conflict");
    } else {
      this.setValue(value);
      this.highlight();
    }

    this.el.dispatchEvent(
      new CustomEvent("live_collab:remote_change", {
        bubbles: true,
        detail: { field: payload.field, value, by: payload.by, applied: !editing }
      })
    );
  },

  handleApplyRemote(event) {
    const value = event && event.detail ? event.detail.value : undefined;
    if (value === undefined) return;
    this.setValue(value == null ? "" : String(value));
    this.el.classList.remove("collab-conflict");
    this.highlight();
    // Let phx-change forms (and any other listeners) see the new value.
    this.el.dispatchEvent(new Event("input", { bubbles: true }));
  },

  setValue(value) {
    if (this.el.type === "checkbox" || this.el.type === "radio") {
      this.el.checked = value === "true" || value === this.el.value;
    } else {
      this.el.value = value;
    }
  },

  highlight() {
    this.el.classList.add("collab-remote-updated");
    clearTimeout(this.highlightTimer);
    this.highlightTimer = setTimeout(() => this.el.classList.remove("collab-remote-updated"), HIGHLIGHT_MS);
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
