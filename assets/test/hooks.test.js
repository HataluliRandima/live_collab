import { test, describe, beforeEach, mock } from "node:test";
import assert from "node:assert/strict";
import { setupDom, element, mountHook } from "./harness.js";

let env;
let LiveCollabCursor, LiveCollabField, LiveCollabElement, LiveCollabViewport, LiveCollabSelection, LiveCollabStatus, LiveCollabHooks;

beforeEach(async () => {
  env = setupDom();
  ({ LiveCollabCursor, LiveCollabField, LiveCollabElement, LiveCollabViewport, LiveCollabSelection, LiveCollabStatus, LiveCollabHooks } =
    await import("../js/live_collab/index.js"));
});

const remoteCursor = (overrides = {}) => ({
  client_id: "cli_peer",
  user_name: "Peer",
  user_color: "#DC2626",
  x: 0.5,
  y: 0.5,
  container_id: "board",
  ...overrides
});

describe("package entry point", () => {
  test("exports every hook", () => {
    assert.deepEqual(Object.keys(LiveCollabHooks).sort(), [
      "LiveCollabCursor",
      "LiveCollabElement",
      "LiveCollabField",
      "LiveCollabSelection",
      "LiveCollabStatus",
      "LiveCollabViewport"
    ]);
  });
});

describe("LiveCollabCursor", () => {
  test("regression: remote names and colors cannot inject markup (stored XSS)", () => {
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);

    h.server(
      "live_collab:cursor_moved",
      remoteCursor({
        user_name: '<img src=x onerror="window.__pwned=1">',
        user_color: 'red" onmouseover="window.__pwned=1'
      })
    );

    assert.equal(el.querySelectorAll("img").length, 0);
    assert.equal(el.querySelector("[onmouseover]"), null);
    const pill = el.querySelector(".live-collab-cursor-pill");
    assert.equal(pill.textContent, '<img src=x onerror="window.__pwned=1">');
    assert.equal(el.querySelector("path").getAttribute("fill"), "#4F46E5");
    assert.equal(env.window.__pwned, undefined);
  });

  test("ignores malformed payloads", () => {
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);

    for (const bad of [{ x: "0.5" }, { x: NaN }, { y: Infinity }, { client_id: 42 }, { x: undefined }]) {
      h.server("live_collab:cursor_moved", remoteCursor(bad));
    }
    h.server("live_collab:cursor_moved", null);

    assert.equal(el.querySelectorAll(".live-collab-remote-cursor").length, 0);
  });

  test("ignores cursors for other containers", () => {
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);
    h.server("live_collab:cursor_moved", remoteCursor({ container_id: "other" }));
    assert.equal(el.querySelectorAll(".live-collab-remote-cursor").length, 0);
  });

  test("removes a cursor when the collaborator leaves (peers_left)", () => {
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);
    h.server("live_collab:cursor_moved", remoteCursor());
    h.server("live_collab:cursor_moved", remoteCursor({ client_id: "cli_other" }));

    h.server("live_collab:peers_left", { client_ids: ["cli_peer"] });

    assert.equal(el.querySelectorAll(".live-collab-remote-cursor").length, 1);
    assert.equal(h.hook.remoteCursors.has("cli_peer"), false);
  });

  test("cursor_left for another container does not remove the cursor", () => {
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);
    h.server("live_collab:cursor_moved", remoteCursor());
    h.server("live_collab:cursor_left", { client_id: "cli_peer", container_id: "sidebar" });
    assert.equal(h.hook.remoteCursors.size, 1);
    h.server("live_collab:cursor_left", { client_id: "cli_peer", container_id: "board" });
    assert.equal(h.hook.remoteCursors.size, 0);
  });

  test("regression: idle cursors fade and are then removed from the DOM", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);
    h.server("live_collab:cursor_moved", remoteCursor());
    const node = el.querySelector(".live-collab-remote-cursor");

    t.mock.timers.tick(4000);
    assert.equal(node.style.opacity, "0");
    assert.equal(h.hook.remoteCursors.size, 1);

    t.mock.timers.tick(1000);
    assert.equal(h.hook.remoteCursors.size, 0);
    assert.equal(node.isConnected, false);
  });

  test("the animation loop stops once cursors settle", () => {
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);
    assert.equal(env.pendingFrames(), 0, "no frames scheduled while idle");

    h.server("live_collab:cursor_moved", remoteCursor({ x: 0.1, y: 0.1 }));
    h.server("live_collab:cursor_moved", remoteCursor({ x: 0.9, y: 0.9 }));

    let frames = 0;
    while (env.runFrame() > 0 && frames < 200) frames++;

    assert.ok(frames > 1 && frames < 200, `loop ran ${frames} frames then stopped`);
    assert.equal(h.hook.animationFrameId, null);
    const cursor = h.hook.remoteCursors.get("cli_peer");
    assert.equal(cursor.currentX, 0.9);
    assert.equal(cursor.el.style.transform, "translate3d(180px, 90px, 0)");
  });

  test("throttles and deadbands local pointer moves; never sends a client_id", (t) => {
    t.mock.timers.enable({ apis: ["Date"] });
    let now = 1000;
    t.mock.method(performance, "now", () => now);

    const el = element("div", { "data-collab-container": "board", "data-collab-throttle": "30" });
    const h = mountHook(LiveCollabCursor, el);
    const move = (x, y) => el.dispatchEvent(new env.window.MouseEvent("pointermove", { clientX: x, clientY: y }));

    move(100, 50);
    move(120, 50); // within throttle window
    now += 31;
    move(100.1, 50); // below deadband
    now += 31;
    move(150, 75);

    const sent = h.events("live_collab:cursor_move");
    assert.deepEqual(
      sent.map((e) => [e.payload.x, e.payload.y]),
      [
        [0.5, 0.5],
        [0.75, 0.75]
      ]
    );
    assert.ok(sent.every((e) => !("client_id" in e.payload)));
  });

  test("destroyed() cleans up and survives a disconnected LiveView", () => {
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);
    h.server("live_collab:cursor_moved", remoteCursor());
    h.hook.__pushThrows = true;

    assert.doesNotThrow(() => h.hook.destroyed());
    assert.equal(el.querySelector(".live-collab-cursor-layer"), null);
    assert.equal(h.hook.remoteCursors.size, 0);
  });
});

describe("LiveCollabField", () => {
  const input = (attrs = {}) => element("input", { "data-collab-field": "order.name", "data-collab-locked": "false", ...attrs });

  test("focus claims, debounced blur releases with the field name", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const el = input();
    const h = mountHook(LiveCollabField, el);

    el.dispatchEvent(new env.window.FocusEvent("focus"));
    el.dispatchEvent(new env.window.FocusEvent("focus"));
    el.dispatchEvent(new env.window.FocusEvent("blur"));
    assert.equal(h.events("live_collab:field_blur").length, 0);
    t.mock.timers.tick(80);

    assert.deepEqual(h.pushes, [
      { event: "live_collab:field_focus", payload: { field: "order.name" } },
      { event: "live_collab:field_blur", payload: { field: "order.name" } }
    ]);
  });

  test("regression: destroying an input with a pending blur still releases the lock", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const el = input();
    const h = mountHook(LiveCollabField, el);

    el.dispatchEvent(new env.window.FocusEvent("focus"));
    el.dispatchEvent(new env.window.FocusEvent("blur"));
    h.hook.destroyed(); // before the 80ms debounce fires

    assert.deepEqual(h.events("live_collab:field_blur"), [
      { event: "live_collab:field_blur", payload: { field: "order.name" } }
    ]);
    t.mock.timers.tick(200);
    assert.equal(h.events("live_collab:field_blur").length, 1);
  });

  test("regression: lock_lost is handled once (no duplicate conflict events)", () => {
    const el = input();
    const h = mountHook(LiveCollabField, el);
    const conflicts = [];
    document.body.addEventListener("live_collab:conflict", (e) => conflicts.push(e.detail));

    el.dispatchEvent(new env.window.FocusEvent("focus"));
    h.server("live_collab:lock_lost", { field: "order.name", locked_by: "Alice" });
    h.server("live_collab:lock_lost:order.name", { field: "order.name", locked_by: "Alice" });

    assert.deepEqual(conflicts, [{ field: "order.name", locked_by: "Alice" }]);
    assert.equal(el.getAttribute("readonly"), "readonly");
    assert.equal(h.handlerCount("live_collab:lock_lost:order.name"), 0);
  });

  test("lock_lost for another field is ignored", () => {
    const el = input();
    const h = mountHook(LiveCollabField, el);
    h.server("live_collab:lock_lost", { field: "other", locked_by: "Bob" });
    assert.equal(el.hasAttribute("readonly"), false);
  });

  test("a field locked by someone else is read-only and does not claim on focus", () => {
    const el = input({ "data-collab-locked": "true" });
    const h = mountHook(LiveCollabField, el);
    el.dispatchEvent(new env.window.FocusEvent("focus"));

    assert.equal(el.getAttribute("readonly"), "readonly");
    assert.equal(el.getAttribute("aria-readonly"), "true");
    assert.equal(h.events("live_collab:field_focus").length, 0);
  });

  test("unlocking via a server re-render removes the read-only state", () => {
    const el = input({ "data-collab-locked": "true" });
    const h = mountHook(LiveCollabField, el);
    el.setAttribute("data-collab-locked", "false");
    h.hook.updated();
    assert.equal(el.hasAttribute("readonly"), false);
  });
});

describe("LiveCollabElement", () => {
  test("click selects, focus views, leaving releases with the element id", () => {
    const el = element("tr", { "data-collab-element": "row:1" });
    const h = mountHook(LiveCollabElement, el);

    el.dispatchEvent(new env.window.FocusEvent("focusin"));
    el.dispatchEvent(new env.window.MouseEvent("click"));
    el.dispatchEvent(new env.window.MouseEvent("click"));
    el.dispatchEvent(new env.window.FocusEvent("focusin")); // no downgrade to viewing
    el.dispatchEvent(new env.window.FocusEvent("focusout", { relatedTarget: null }));

    assert.deepEqual(h.pushes, [
      { event: "live_collab:element_active", payload: { element: "row:1", type: "viewing" } },
      { event: "live_collab:element_active", payload: { element: "row:1", type: "selected" } },
      { event: "live_collab:element_inactive", payload: { element: "row:1" } }
    ]);
  });

  test("hover intent is debounced", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const el = element("tr", { "data-collab-element": "row:2", "data-collab-hover-intent": "300" });
    const h = mountHook(LiveCollabElement, el);

    el.dispatchEvent(new env.window.MouseEvent("mouseenter"));
    t.mock.timers.tick(299);
    el.dispatchEvent(new env.window.MouseEvent("mouseleave"));
    t.mock.timers.tick(1000);
    assert.equal(h.pushes.length, 0);

    el.dispatchEvent(new env.window.MouseEvent("mouseenter"));
    t.mock.timers.tick(300);
    assert.equal(h.events("live_collab:element_active").length, 1);
  });

  test("destroyed releases an active element", () => {
    const el = element("tr", { "data-collab-element": "row:3" });
    const h = mountHook(LiveCollabElement, el);
    el.dispatchEvent(new env.window.MouseEvent("click"));
    h.hook.destroyed();
    assert.equal(h.events("live_collab:element_inactive").length, 1);
  });
});

describe("LiveCollabViewport", () => {
  test("follows the presenter chosen via a window-level start_follow event", () => {
    const el = element("div", { "data-collab-container": "doc" });
    const h = mountHook(LiveCollabViewport, el);
    const scrolls = [];
    el.scrollTo = (opts) => scrolls.push(opts);
    Object.defineProperties(el, {
      scrollHeight: { value: 1100 },
      clientHeight: { value: 100 },
      scrollWidth: { value: 100 },
      clientWidth: { value: 100 }
    });

    env.window.dispatchEvent(new CustomEvent("live_collab:start_follow", { detail: { client_id: "cli_lead" } }));
    h.server("live_collab:viewport_moved", { client_id: "cli_other", scroll_x: 0, scroll_y: 0.9, container_id: "doc" });
    h.server("live_collab:viewport_moved", { client_id: "cli_lead", scroll_x: 0, scroll_y: 0.5, container_id: "doc" });

    assert.deepEqual(scrolls, [{ left: 0, top: 500, behavior: "smooth" }]);
  });

  test("start_follow scoped to another container is ignored", () => {
    const el = element("div", { "data-collab-container": "doc" });
    const h = mountHook(LiveCollabViewport, el);
    env.window.dispatchEvent(
      new CustomEvent("live_collab:start_follow", { detail: { client_id: "cli_lead", container_id: "other" } })
    );
    assert.equal(h.hook.followingClientId, null);
  });

  test("a stopped spotlight releases followers", () => {
    const el = element("div", { "data-collab-container": "doc", "data-collab-auto-follow": "true" });
    const h = mountHook(LiveCollabViewport, el);
    h.server("live_collab:spotlight_status", { client_id: "cli_lead", active: true });
    assert.equal(h.hook.followingClientId, "cli_lead");
    h.server("live_collab:spotlight_status", { client_id: "cli_lead", active: false });
    assert.equal(h.hook.followingClientId, null);
  });

  test("regression: window listeners are removed on destroy", () => {
    const el = element("div", { "data-collab-container": "doc" });
    const added = mock.method(env.window, "addEventListener");
    const removed = mock.method(env.window, "removeEventListener");
    const h = mountHook(LiveCollabViewport, el);
    h.hook.destroyed();

    const names = (m) => m.mock.calls.map((c) => c.arguments[0]).filter((n) => n.startsWith("live_collab:")).sort();
    assert.deepEqual(names(added), ["live_collab:start_follow", "live_collab:stop_follow"]);
    assert.deepEqual(names(removed), names(added));
  });

  test("presenters broadcast normalized scroll positions without a client_id", () => {
    const el = element("div", { "data-collab-container": "doc", "data-collab-presenter": "true" });
    Object.defineProperties(el, {
      scrollTop: { value: 250, writable: true },
      scrollHeight: { value: 600 },
      clientHeight: { value: 100 },
      scrollWidth: { value: 100 },
      clientWidth: { value: 100 }
    });
    const h = mountHook(LiveCollabViewport, el);
    el.dispatchEvent(new env.window.Event("scroll"));

    assert.deepEqual(h.events("live_collab:viewport_move")[0].payload, {
      scroll_x: 0,
      scroll_y: 0.5,
      zoom: 1.0,
      container_id: "doc"
    });
  });
});

describe("LiveCollabSelection", () => {
  test("renders remote selections safely and removes them when peers leave", () => {
    const el = element("div", { "data-collab-container": "canvas" });
    const h = mountHook(LiveCollabSelection, el);

    h.server("live_collab:selection_moved", {
      client_id: "cli_peer",
      user_name: "<b>bold</b>",
      user_color: "url(javascript:alert(1))",
      x: 0.1,
      y: 0.2,
      width: 0.5,
      height: 0.5,
      container_id: "canvas"
    });

    const box = el.querySelector(".live-collab-selection-box");
    assert.equal(el.querySelectorAll("b").length, 0);
    assert.equal(box.querySelector(".live-collab-selection-tag").textContent, "<b>bold</b>'s selection");
    assert.match(box.style.border, /2px solid/);
    assert.ok(!box.style.border.includes("javascript"));
    assert.equal(box.style.width, "100px");

    h.server("live_collab:peers_left", { client_ids: ["cli_peer"] });
    assert.equal(el.querySelector(".live-collab-selection-box"), null);
  });

  test("forwards local selections, throttled, always delivering the last one", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    let now = 1000;
    t.mock.method(performance, "now", () => now);

    const el = element("div", { "data-collab-container": "canvas" });
    const h = mountHook(LiveCollabSelection, el);
    const select = (x) =>
      el.dispatchEvent(
        new CustomEvent("live_collab:local_selection", { detail: { x, y: 0, width: 0.1, height: 0.1, selected_ids: ["a"] } })
      );

    select(0.1);
    select(0.2);
    select(0.3);
    assert.equal(h.events("live_collab:selection_move").length, 1);

    now += 50;
    t.mock.timers.tick(50);
    const sent = h.events("live_collab:selection_move").map((e) => e.payload.x);
    assert.deepEqual(sent, [0.1, 0.3]);

    el.dispatchEvent(new CustomEvent("live_collab:local_selection_clear"));
    assert.deepEqual(h.events("live_collab:selection_clear")[0].payload, { container_id: "canvas" });
  });

  test("ignores malformed local selections", () => {
    const el = element("div", { "data-collab-container": "canvas" });
    const h = mountHook(LiveCollabSelection, el);
    el.dispatchEvent(new CustomEvent("live_collab:local_selection", { detail: { x: "0.1", y: 0, width: 1, height: 1 } }));
    assert.equal(h.pushes.length, 0);
  });
});

describe("LiveCollabStatus", () => {
  const setVisibility = (state) => {
    Object.defineProperty(document, "visibilityState", { value: state, configurable: true });
    document.dispatchEvent(new env.window.Event("visibilitychange"));
  };

  test("goes away after the idle timeout and back on activity, pushing only changes", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const el = element("div", { "data-collab-idle-after": "1000" });
    const h = mountHook(LiveCollabStatus, el);

    t.mock.timers.tick(999);
    assert.equal(h.pushes.length, 0);
    t.mock.timers.tick(1);
    env.window.dispatchEvent(new env.window.Event("pointermove"));
    env.window.dispatchEvent(new env.window.Event("pointermove"));
    env.window.dispatchEvent(new env.window.Event("keydown"));

    assert.deepEqual(
      h.pushes.map((p) => p.payload.status),
      ["away", "active"]
    );
  });

  test("activity keeps postponing the idle timer", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const h = mountHook(LiveCollabStatus, element("div", { "data-collab-idle-after": "1000" }));

    for (let i = 0; i < 5; i++) {
      t.mock.timers.tick(900);
      env.window.dispatchEvent(new env.window.Event("wheel"));
    }
    assert.equal(h.pushes.length, 0);
  });

  test("a hidden page is away immediately and active when visible again", () => {
    const h = mountHook(LiveCollabStatus, element("div"));
    setVisibility("hidden");
    setVisibility("visible");
    assert.deepEqual(
      h.events("live_collab:status").map((p) => p.payload),
      [{ status: "away" }, { status: "active" }]
    );
    setVisibility("visible");
  });

  test("re-announces away after a reconnect", () => {
    const h = mountHook(LiveCollabStatus, element("div"));
    setVisibility("hidden");
    h.hook.reconnected();
    assert.deepEqual(
      h.pushes.map((p) => p.payload.status),
      ["away", "away"]
    );
    setVisibility("visible");
  });

  test("destroyed() removes window and document listeners", () => {
    const winAdd = mock.method(env.window, "addEventListener");
    const winRemove = mock.method(env.window, "removeEventListener");
    const h = mountHook(LiveCollabStatus, element("div"));
    h.hook.destroyed();
    assert.equal(winRemove.mock.callCount(), winAdd.mock.callCount());
    env.window.dispatchEvent(new env.window.Event("keydown"));
    assert.equal(h.pushes.length, 0);
  });
});

describe("overlay layers survive LiveView patches", () => {
  test("hooks adopt a server-rendered [data-collab-layer] overlay and leave it in place on destroy", () => {
    const el = element("div", { "data-collab-container": "board" });
    const overlay = document.createElement("div");
    overlay.setAttribute("data-collab-layer", "");
    overlay.setAttribute("phx-update", "ignore");
    el.appendChild(overlay);

    const h = mountHook(LiveCollabCursor, el);
    h.server("live_collab:cursor_moved", remoteCursor());

    assert.equal(el.children.length, 1, "no second layer created");
    assert.equal(overlay.querySelectorAll(".live-collab-remote-cursor").length, 1);
    h.hook.destroyed();
    assert.equal(overlay.isConnected, true);
  });

  test("regression: a hook-created layer removed by a LiveView patch is re-attached with its cursors", () => {
    const el = element("div", { "data-collab-container": "board" });
    const h = mountHook(LiveCollabCursor, el);
    h.server("live_collab:cursor_moved", remoteCursor());
    const layer = el.querySelector(".live-collab-cursor-layer");

    layer.remove(); // what morphdom does to children the server did not render
    h.hook.updated();

    assert.equal(layer.parentNode, el);
    assert.equal(el.querySelectorAll(".live-collab-remote-cursor").length, 1);
  });

  test("the selection hook re-attaches its layer too", () => {
    const el = element("div", { "data-collab-container": "canvas" });
    const h = mountHook(LiveCollabSelection, el);
    const layer = el.querySelector(".live-collab-selection-layer");
    layer.remove();
    h.hook.updated();
    assert.equal(layer.parentNode, el);
  });
});

describe("LiveCollabField: handoff and remote changes", () => {
  const input = (attrs = {}) =>
    element("input", { "data-collab-field": "title", "data-collab-locked": "false", value: "old", ...attrs });

  test("lock_granted unlocks and focuses the input, which claims the field", () => {
    const el = input({ "data-collab-locked": "true" });
    const h = mountHook(LiveCollabField, el);
    assert.equal(el.getAttribute("readonly"), "readonly");

    h.server("live_collab:lock_granted", { field: "title", granted_by: "Alice" });

    assert.equal(document.activeElement, el);
    assert.equal(el.hasAttribute("readonly"), false);
    assert.deepEqual(h.events("live_collab:field_focus"), [
      { event: "live_collab:field_focus", payload: { field: "title" } }
    ]);
  });

  test("a saved change updates an input you are not editing, with a temporary highlight", (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const el = input();
    const h = mountHook(LiveCollabField, el);
    const seen = [];
    document.body.addEventListener("live_collab:remote_change", (e) => seen.push(e.detail));

    h.server("live_collab:field_changed", { field: "title", value: "Alice's title", by: "Alice" });

    assert.equal(el.value, "Alice's title");
    assert.ok(el.classList.contains("collab-remote-updated"));
    t.mock.timers.tick(2000);
    assert.ok(!el.classList.contains("collab-remote-updated"));
    assert.deepEqual(seen, [{ field: "title", value: "Alice's title", by: "Alice", applied: true }]);
  });

  test("never overwrites text the user is typing; flags a conflict instead", () => {
    const el = input();
    const h = mountHook(LiveCollabField, el);
    el.focus();
    el.value = "my unsaved text";

    h.server("live_collab:field_changed", { field: "title", value: "theirs", by: "Alice" });
    h.server("live_collab:field_conflict", { field: "title", value: "theirs", by: "Alice" });

    assert.equal(el.value, "my unsaved text");
    assert.ok(el.classList.contains("collab-conflict"));

    h.server("live_collab:change_dismissed", { field: "title" });
    assert.ok(!el.classList.contains("collab-conflict"));
  });

  test("'Use theirs' (apply_remote) sets the value and fires input for phx-change", () => {
    const el = input();
    mountHook(LiveCollabField, el);
    el.classList.add("collab-conflict");
    const inputs = [];
    el.addEventListener("input", () => inputs.push(el.value));

    el.dispatchEvent(new CustomEvent("live_collab:apply_remote", { detail: { value: "theirs" } }));

    assert.equal(el.value, "theirs");
    assert.deepEqual(inputs, ["theirs"]);
    assert.ok(!el.classList.contains("collab-conflict"));
  });

  test("changes for other fields are ignored", () => {
    const el = input();
    const h = mountHook(LiveCollabField, el);
    h.server("live_collab:field_changed", { field: "other", value: "x" });
    h.server("live_collab:lock_granted", { field: "other" });
    assert.equal(el.value, "old");
    assert.equal(h.events("live_collab:field_focus").length, 0);
  });
});

