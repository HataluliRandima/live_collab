/**
 * LiveCollab Client Library
 *
 * Usage in app.js:
 *
 * ```javascript
 * import { LiveSocket } from "phoenix_live_view"
 * import { LiveCollabHooks } from "live_collab"
 *
 * let liveSocket = new LiveSocket("/live", Socket, {
 *   params: {_csrf_token: csrfToken},
 *   hooks: { ...LiveCollabHooks, ...customHooks }
 * })
 * ```
 */

import { LiveCollabField } from "./hooks/live_collab_field.js";

export const LiveCollabHooks = {
  LiveCollabField
};

export { LiveCollabField };
export default LiveCollabHooks;
