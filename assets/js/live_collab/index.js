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
import { LiveCollabCursor } from "./hooks/live_collab_cursor.js";

export const LiveCollabHooks = {
  LiveCollabField,
  LiveCollabElement,
  LiveCollabCursor
};

export { LiveCollabField, LiveCollabElement, LiveCollabCursor };
export default LiveCollabHooks;
