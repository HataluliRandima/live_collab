// Minimal LiveView hook harness on top of jsdom. Hooks are plain objects whose
// methods are called with `this` bound to an instance exposing `el`,
// `pushEvent` and `handleEvent`, exactly like phoenix_live_view does.
import { JSDOM } from "jsdom";

export function setupDom() {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true });
  const { window } = dom;
  const frames = [];

  globalThis.window = window;
  globalThis.document = window.document;
  globalThis.CustomEvent = window.CustomEvent;
  // Hooks construct plain Events too (e.g. "input"); they must be jsdom's.
  globalThis.Event = window.Event;
  globalThis.HTMLElement = window.HTMLElement;
  // Manually driven animation frames, so tests can step the render loop.
  globalThis.requestAnimationFrame = (cb) => frames.push(cb);
  globalThis.cancelAnimationFrame = () => {};
  window.scrollTo = () => {};

  return {
    window,
    runFrame() {
      const pending = frames.splice(0, frames.length);
      pending.forEach((cb) => cb(performance.now()));
      return pending.length;
    },
    pendingFrames: () => frames.length
  };
}

export function element(tag = "div", attrs = {}, rect = { left: 0, top: 0, width: 200, height: 100 }) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  el.getBoundingClientRect = () => ({ ...rect, right: rect.left + rect.width, bottom: rect.top + rect.height });
  document.body.appendChild(el);
  return el;
}

export function mountHook(Hook, el, { pushThrows = false } = {}) {
  const pushes = [];
  const handlers = new Map();
  const hook = Object.create(Hook);

  hook.el = el;
  hook.pushEvent = (event, payload) => {
    if (hook.__pushThrows) throw new Error("unable to push hook event. LiveView not connected");
    pushes.push({ event, payload });
  };
  hook.handleEvent = (event, cb) => {
    if (!handlers.has(event)) handlers.set(event, []);
    handlers.get(event).push(cb);
  };
  hook.__pushThrows = pushThrows;
  hook.mounted();

  return {
    hook,
    pushes,
    handlerCount: (event) => (handlers.get(event) || []).length,
    server(event, payload) {
      (handlers.get(event) || []).forEach((cb) => cb(payload));
    },
    events: (name) => pushes.filter((p) => p.event === name)
  };
}
