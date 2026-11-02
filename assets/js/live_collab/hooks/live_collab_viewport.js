/**
 * LiveCollab - Viewport & Scroll Following Hook
 *
 * Provides real-time presenter following and collaborative scroll synchronization.
 *
 * Capabilities:
 * - Normalized scroll positions [0.0, 1.0] across responsive layouts and window geometries
 * - Echo loop defense: Suppresses scroll broadcasts during programmatic follower scrolling
 * - Follower auto-breakout: Automatically disengages follow mode when user manually scrolls
 * - Smooth scroll interpolation via native scrollTo({ behavior: 'smooth' })
 * - Spotlight presenter broadcast support
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

export const LiveCollabViewport = {
  mounted() {
    this.clientId = getTabClientId();
    this.containerId = this.el.dataset.collabContainer || "default";
    this.throttleMs = parseInt(this.el.dataset.collabThrottle, 10) || 40;
    this.isPresenter = this.el.dataset.collabPresenter === "true";
    this.followingClientId = this.el.dataset.collabFollowing || null;

    this.lastSentAt = 0;
    this.isProgrammaticScroll = false;
    this.programmaticScrollTimer = null;

    this.handleScroll = this.handleScroll.bind(this);
    this.handleViewportMoved = this.handleViewportMoved.bind(this);
    this.handleSpotlightStatus = this.handleSpotlightStatus.bind(this);

    // Scroll listener on container or window
    this.target = this.el === document.body || this.el.dataset.collabWindow === "true" ? window : this.el;
    this.target.addEventListener("scroll", this.handleScroll, { passive: true });

    // Handle remote viewport broadcasts pushed from server (zero assigns diffing)
    this.handleEvent("live_collab:viewport_moved", this.handleViewportMoved);
    this.handleEvent("live_collab:spotlight_status", this.handleSpotlightStatus);

    // Custom DOM events for UI control
    this.el.addEventListener("live_collab:start_follow", (e) => {
      this.followingClientId = e.detail.client_id;
    });

    this.el.addEventListener("live_collab:stop_follow", () => {
      this.followingClientId = null;
    });
  },

  updated() {
    this.isPresenter = this.el.dataset.collabPresenter === "true";
    this.followingClientId = this.el.dataset.collabFollowing || this.followingClientId;
  },

  destroyed() {
    if (this.programmaticScrollTimer) {
      clearTimeout(this.programmaticScrollTimer);
    }
    this.target.removeEventListener("scroll", this.handleScroll);
  },

  handleScroll(_event) {
    // Crucial: Ignore scroll events triggered programmatically by follow synchronization
    // to prevent infinite feedback loops!
    if (this.isProgrammaticScroll) {
      return;
    }

    // If follower manually scrolls with wheel or scrollbar, break out of follow mode
    if (this.followingClientId) {
      const brokenClientId = this.followingClientId;
      this.followingClientId = null;

      this.el.dispatchEvent(new CustomEvent("live_collab:follow_broken", {
        bubbles: true,
        detail: { leader_client_id: brokenClientId }
      }));
    }

    // Only broadcast scroll if this client is presenting / leading
    if (!this.isPresenter && !this.el.dataset.collabBroadcast) {
      return;
    }

    const now = performance.now();
    if (now - this.lastSentAt < this.throttleMs) {
      return;
    }

    const scrollMetrics = this.getScrollMetrics();
    if (!scrollMetrics) return;

    this.lastSentAt = now;

    this.pushEvent("live_collab:viewport_move", {
      scroll_x: scrollMetrics.pctX,
      scroll_y: scrollMetrics.pctY,
      zoom: 1.0,
      container_id: this.containerId,
      client_id: this.clientId
    });
  },

  handleViewportMoved(payload) {
    if (payload.client_id === this.clientId) return;
    if (payload.container_id && payload.container_id !== this.containerId) return;

    // Only apply scroll synchronization if currently following this broadcaster
    if (this.followingClientId === payload.client_id) {
      this.scrollToNormalized(payload.scroll_x, payload.scroll_y);
    }

    // Dispatch DOM event so an optional minimap or viewport frustum overlay can render
    this.el.dispatchEvent(new CustomEvent("live_collab:peer_viewport", {
      bubbles: true,
      detail: payload
    }));
  },

  handleSpotlightStatus(payload) {
    if (payload.client_id === this.clientId) return;

    if (payload.active && this.el.dataset.collabAutoFollow === "true") {
      this.followingClientId = payload.client_id;
    }

    this.el.dispatchEvent(new CustomEvent("live_collab:spotlight_change", {
      bubbles: true,
      detail: payload
    }));
  },

  getScrollMetrics() {
    const isWin = this.target === window;
    const scrollLeft = isWin ? window.scrollX || document.documentElement.scrollLeft : this.target.scrollLeft;
    const scrollTop = isWin ? window.scrollY || document.documentElement.scrollTop : this.target.scrollTop;
    const scrollWidth = isWin ? document.documentElement.scrollWidth : this.target.scrollWidth;
    const scrollHeight = isWin ? document.documentElement.scrollHeight : this.target.scrollHeight;
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
    const scrollWidth = isWin ? document.documentElement.scrollWidth : this.target.scrollWidth;
    const scrollHeight = isWin ? document.documentElement.scrollHeight : this.target.scrollHeight;
    const clientWidth = isWin ? window.innerWidth : this.target.clientWidth;
    const clientHeight = isWin ? window.innerHeight : this.target.clientHeight;

    const targetX = pctX * Math.max(scrollWidth - clientWidth, 0);
    const targetY = pctY * Math.max(scrollHeight - clientHeight, 0);

    // Set guard flag before scrolling
    this.isProgrammaticScroll = true;

    if (isWin) {
      window.scrollTo({ left: targetX, top: targetY, behavior: "smooth" });
    } else {
      this.target.scrollTo({ left: targetX, top: targetY, behavior: "smooth" });
    }

    // Reset guard after smooth scroll animation completes (~350ms)
    if (this.programmaticScrollTimer) clearTimeout(this.programmaticScrollTimer);
    this.programmaticScrollTimer = setTimeout(() => {
      this.isProgrammaticScroll = false;
      this.programmaticScrollTimer = null;
    }, 400);
  }
};

export default LiveCollabViewport;

