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
import { LiveCollabViewport } from "./hooks/live_collab_viewport.js";
import { LiveCollabSelection } from "./hooks/live_collab_selection.js";

export const LiveCollabHooks = {
  LiveCollabField,
  LiveCollabElement,
  LiveCollabCursor,
  LiveCollabViewport,
  LiveCollabSelection
};

export {
  LiveCollabField,
  LiveCollabElement,
  LiveCollabCursor,
  LiveCollabViewport,
  LiveCollabSelection
};

export default LiveCollabHooks;
