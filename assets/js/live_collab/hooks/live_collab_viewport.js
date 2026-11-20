/**
 * LiveCollab - Viewport & Scroll Following Hook
 *
 * - Presenters (`data-collab-presenter="true"`) broadcast normalized scroll
 *   positions [0.0, 1.0], throttled (default 40ms)
 * - Followers scroll to the followed presenter's position; programmatic scrolls
 *   are not re-broadcast (no feedback loops)
 * - A manual scroll by a follower disengages follow mode and dispatches
 *   `live_collab:follow_broken`
 * - `live_collab:start_follow` / `live_collab:stop_follow` DOM events (as
 *   dispatched by `<.follow_pill>`) are handled on `window`, so the control can
 *   live anywhere on the page; `detail.container_id` scopes them to one container
 * - With `data-collab-auto-follow="true"`, a started spotlight is followed
 *   automatically; a stopped or departed presenter is unfollowed
 */

import { finite, safePush } from "../utils.js";

const PROGRAMMATIC_SCROLL_GUARD_MS = 400;

export const LiveCollabViewport = {
  mounted() {
    this.containerId = this.el.dataset.collabContainer || "default";
    this.throttleMs = parseInt(this.el.dataset.collabThrottle, 10) || 40;
    this.isPresenter = this.el.dataset.collabPresenter === "true";
    this.followingClientId = this.el.dataset.collabFollowing || null;

    this.lastSentAt = 0;
    this.isProgrammaticScroll = false;
    this.programmaticScrollTimer = null;

    this.handleScroll = this.handleScroll.bind(this);
    this.handleStartFollow = this.handleStartFollow.bind(this);
    this.handleStopFollow = this.handleStopFollow.bind(this);

    this.target = this.el === document.body || this.el.dataset.collabWindow === "true" ? window : this.el;
    this.target.addEventListener("scroll", this.handleScroll, { passive: true });
    window.addEventListener("live_collab:start_follow", this.handleStartFollow);
    window.addEventListener("live_collab:stop_follow", this.handleStopFollow);

    this.handleEvent("live_collab:viewport_moved", (payload) => this.handleViewportMoved(payload));
    this.handleEvent("live_collab:spotlight_status", (payload) => this.handleSpotlightStatus(payload));
  },

  updated() {
    this.isPresenter = this.el.dataset.collabPresenter === "true";
    if (this.el.dataset.collabFollowing) this.followingClientId = this.el.dataset.collabFollowing;
  },

  destroyed() {
    clearTimeout(this.programmaticScrollTimer);
    this.target.removeEventListener("scroll", this.handleScroll);
    window.removeEventListener("live_collab:start_follow", this.handleStartFollow);
    window.removeEventListener("live_collab:stop_follow", this.handleStopFollow);
  },

  targetsThisContainer(event) {
    const containerId = event && event.detail && event.detail.container_id;
    return containerId == null || containerId === this.containerId;
  },

  handleStartFollow(event) {
    if (!this.targetsThisContainer(event)) return;
    const clientId = event.detail && event.detail.client_id;
    if (typeof clientId === "string") this.followingClientId = clientId;
  },

  handleStopFollow(event) {
    if (this.targetsThisContainer(event)) this.followingClientId = null;
  },

  handleScroll(_event) {
    if (this.isProgrammaticScroll) return;

    if (this.followingClientId) {
      const brokenClientId = this.followingClientId;
      this.followingClientId = null;
      this.el.dispatchEvent(
        new CustomEvent("live_collab:follow_broken", { bubbles: true, detail: { leader_client_id: brokenClientId } })
      );
    }

    if (!this.isPresenter && !this.el.dataset.collabBroadcast) return;

    const now = performance.now();
    if (now - this.lastSentAt < this.throttleMs) return;
    this.lastSentAt = now;

    const metrics = this.getScrollMetrics();
    safePush(this, "live_collab:viewport_move", {
      scroll_x: metrics.pctX,
      scroll_y: metrics.pctY,
      zoom: 1.0,
      container_id: this.containerId
    });
  },

  handleViewportMoved(payload) {
    if (!payload || (payload.container_id != null && payload.container_id !== this.containerId)) return;

    const x = finite(payload.scroll_x);
    const y = finite(payload.scroll_y);
    if (x === null || y === null) return;

    if (this.followingClientId && this.followingClientId === payload.client_id) {
      this.scrollToNormalized(x, y);
    }

    // For minimaps / viewport frustum overlays.
    this.el.dispatchEvent(new CustomEvent("live_collab:peer_viewport", { bubbles: true, detail: payload }));
  },

  handleSpotlightStatus(payload) {
    if (!payload) return;

    if (payload.active && this.el.dataset.collabAutoFollow === "true") {
      this.followingClientId = payload.client_id;
    } else if (!payload.active && this.followingClientId === payload.client_id) {
      this.followingClientId = null;
    }

    this.el.dispatchEvent(new CustomEvent("live_collab:spotlight_change", { bubbles: true, detail: payload }));
  },

  getScrollMetrics() {
    const isWin = this.target === window;
    const doc = document.documentElement;
    const scrollLeft = isWin ? window.scrollX || doc.scrollLeft : this.target.scrollLeft;
    const scrollTop = isWin ? window.scrollY || doc.scrollTop : this.target.scrollTop;
    const scrollWidth = isWin ? doc.scrollWidth : this.target.scrollWidth;
    const scrollHeight = isWin ? doc.scrollHeight : this.target.scrollHeight;
    const clientWidth = isWin ? window.innerWidth : this.target.clientWidth;
    const clientHeight = isWin ? window.innerHeight : this.target.clientHeight;

    const maxScrollX = Math.max(scrollWidth - clientWidth, 1);
    const maxScrollY = Math.max(scrollHeight - clientHeight, 1);

    return {
      pctX: Math.min(Math.max(scrollLeft / maxScrollX, 0), 1),
      pctY: Math.min(Math.max(scrollTop / maxScrollY, 0), 1)
    };
  },

  scrollToNormalized(pctX, pctY) {
    const isWin = this.target === window;
    const doc = document.documentElement;
    const scrollWidth = isWin ? doc.scrollWidth : this.target.scrollWidth;
    const scrollHeight = isWin ? doc.scrollHeight : this.target.scrollHeight;
    const clientWidth = isWin ? window.innerWidth : this.target.clientWidth;
    const clientHeight = isWin ? window.innerHeight : this.target.clientHeight;

    const left = Math.min(Math.max(pctX, 0), 1) * Math.max(scrollWidth - clientWidth, 0);
    const top = Math.min(Math.max(pctY, 0), 1) * Math.max(scrollHeight - clientHeight, 0);

    this.isProgrammaticScroll = true;
    (isWin ? window : this.target).scrollTo({ left, top, behavior: "smooth" });

    clearTimeout(this.programmaticScrollTimer);
    this.programmaticScrollTimer = setTimeout(() => {
      this.isProgrammaticScroll = false;
      this.programmaticScrollTimer = null;
    }, PROGRAMMATIC_SCROLL_GUARD_MS);
  }
};

export default LiveCollabViewport;
