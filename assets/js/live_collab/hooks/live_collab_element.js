/**
 * LiveCollab - Collaborative Element & Row Hook
 *
 * Activity indicators for table rows, cards and sections.
 *
 * - `click` marks the element `selected`; keyboard focus (`focusin`) marks it `viewing`
 * - Optional hover intent (`data-collab-hover-intent="300"`) debounces mouse
 *   travel so sweeping across a table does not write to Presence for every row
 * - Releases name the element they release, so a late release from the
 *   previous row never clears the current one
 */

import { safePush } from "../utils.js";

export const LiveCollabElement = {
  mounted() {
    this.elementId = this.readElementId();
    this.type = this.el.dataset.collabType || "viewing";
    this.hoverIntentMs = parseInt(this.el.dataset.collabHoverIntent, 10) || null;
    this.hoverTimer = null;
    this.activeType = null;

    if (!this.elementId) {
      console.warn("[LiveCollab] LiveCollabElement mounted without data-collab-element or id:", this.el);
      return;
    }

    this.handleClick = () => this.activateElement("selected");
    this.handleFocusIn = () => this.activateElement("viewing");
    this.handleFocusOut = this.handleFocusOut.bind(this);
    this.handleMouseEnter = this.handleMouseEnter.bind(this);
    this.handleMouseLeave = this.handleMouseLeave.bind(this);

    this.el.addEventListener("click", this.handleClick);
    this.el.addEventListener("focusin", this.handleFocusIn);
    this.el.addEventListener("focusout", this.handleFocusOut);

    if (this.hoverIntentMs && this.hoverIntentMs > 0) {
      this.el.addEventListener("mouseenter", this.handleMouseEnter);
      this.el.addEventListener("mouseleave", this.handleMouseLeave);
    }
  },

  updated() {
    const newElementId = this.readElementId();
    if (newElementId !== this.elementId) {
      this.deactivateElement();
      this.elementId = newElementId;
    }
    this.type = this.el.dataset.collabType || "viewing";
  },

  destroyed() {
    if (!this.handleClick) return;
    this.clearTimers();
    this.el.removeEventListener("click", this.handleClick);
    this.el.removeEventListener("focusin", this.handleFocusIn);
    this.el.removeEventListener("focusout", this.handleFocusOut);
    this.el.removeEventListener("mouseenter", this.handleMouseEnter);
    this.el.removeEventListener("mouseleave", this.handleMouseLeave);
    this.deactivateElement();
  },

  readElementId() {
    return this.el.dataset.collabElement || this.el.id || null;
  },

  handleFocusOut(event) {
    if (this.el.contains(event.relatedTarget)) return;
    this.deactivateElement();
  },

  handleMouseEnter(_event) {
    this.clearTimers();
    this.hoverTimer = setTimeout(() => {
      this.hoverTimer = null;
      this.activateElement("viewing");
    }, this.hoverIntentMs);
  },

  handleMouseLeave(_event) {
    this.clearTimers();
    if (this.activeType && !this.el.contains(document.activeElement)) {
      this.deactivateElement();
    }
  },

  activateElement(type) {
    const nextType = type || this.type;
    // Never downgrade a click-selection to "viewing" from a hover or focus.
    if (this.activeType === nextType || (this.activeType === "selected" && nextType === "viewing")) {
      return;
    }

    if (safePush(this, "live_collab:element_active", { element: this.elementId, type: nextType })) {
      this.activeType = nextType;
    }
  },

  deactivateElement() {
    if (this.activeType) {
      this.activeType = null;
      safePush(this, "live_collab:element_inactive", { element: this.elementId });
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
