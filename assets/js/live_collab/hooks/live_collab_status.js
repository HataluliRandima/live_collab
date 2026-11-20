/**
 * LiveCollab - Away / Idle Status Hook
 *
 * Rendered once per page by `<.status_reporter>`. Reports this tab as:
 *
 * - "away" when the page becomes hidden (another tab, minimised window), or
 *   after `data-collab-idle-after` ms (default 60000) without pointer, keyboard,
 *   touch, wheel or scroll activity;
 * - "active" again on the next interaction or when the page becomes visible.
 *
 * Only changes are pushed. Activity handlers are passive and only reset a timer,
 * so high-frequency input (pointermove) costs one clearTimeout/setTimeout pair.
 */

import { safePush } from "../utils.js";

const ACTIVITY_EVENTS = ["pointermove", "pointerdown", "keydown", "wheel", "touchstart", "scroll"];

export const LiveCollabStatus = {
  mounted() {
    this.idleAfterMs = parseInt(this.el.dataset.collabIdleAfter, 10) || 60000;
    this.status = "active";
    this.idleTimer = null;

    this.handleActivity = this.handleActivity.bind(this);
    this.handleVisibility = this.handleVisibility.bind(this);

    ACTIVITY_EVENTS.forEach((name) =>
      window.addEventListener(name, this.handleActivity, { passive: true, capture: true })
    );
    document.addEventListener("visibilitychange", this.handleVisibility);

    if (document.visibilityState === "hidden") {
      this.setStatus("away");
    } else {
      this.armIdleTimer();
    }
  },

  // After a LiveView reconnect the server starts a fresh session as "active";
  // re-announce the real state.
  reconnected() {
    const current = this.status;
    this.status = "active";
    if (current === "away") this.setStatus("away");
  },

  destroyed() {
    clearTimeout(this.idleTimer);
    ACTIVITY_EVENTS.forEach((name) =>
      window.removeEventListener(name, this.handleActivity, { passive: true, capture: true })
    );
    document.removeEventListener("visibilitychange", this.handleVisibility);
  },

  handleActivity() {
    if (document.visibilityState === "hidden") return;
    this.setStatus("active");
    this.armIdleTimer();
  },

  handleVisibility() {
    if (document.visibilityState === "hidden") {
      clearTimeout(this.idleTimer);
      this.setStatus("away");
    } else {
      this.setStatus("active");
      this.armIdleTimer();
    }
  },

  armIdleTimer() {
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => this.setStatus("away"), this.idleAfterMs);
  },

  setStatus(status) {
    if (status === this.status) return;
    this.status = status;
    safePush(this, "live_collab:status", { status });
  }
};

export default LiveCollabStatus;
