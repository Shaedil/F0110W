// The page's line to the app. In the M0110 window this is WebView2's
// postMessage; opened in an ordinary browser (for previews) it falls back to
// demo.js, which plays the app's part with sample data.
const webview = window.chrome && window.chrome.webview;
const listeners = new Set();

function deliver(message) {
  for (const listener of listeners) listener(message);
}

let demo = null;
if (webview) {
  webview.addEventListener('message', (event) => deliver(event.data));
} else {
  demo = import('./demo.js').then((module) => module.start(deliver));
}

/** Sends `type` and `body` to the app. */
export function send(type, body = {}) {
  const message = { type, ...body };
  if (webview) webview.postMessage(message);
  else demo.then((d) => d.receive(message));
}

/** Calls `listener` with each message from the app. */
export function listen(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
