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
import { LiveCollabElement } from "./hooks/live_collab_element.js";

export const LiveCollabHooks = {
  LiveCollabField,
  LiveCollabElement
};

export { LiveCollabField, LiveCollabElement };
export default LiveCollabHooks;
