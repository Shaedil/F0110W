// Talks to the app through WebView2 postMessage. In a normal browser it uses
// demo.js and sample data instead.
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

export function send(type, body = {}) {
  const message = { type, ...body };
  if (webview) webview.postMessage(message);
  else demo.then((d) => d.receive(message));
}

export function listen(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
