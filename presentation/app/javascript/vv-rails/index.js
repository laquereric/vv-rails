/**
 * vv-rails client JS — auto-connects the Vv browser plugin to this Rails app.
 *
 * Imported by the Rails app's JS entrypoint:
 *   import { connectVv } from 'vv-rails';
 *
 * The content script in the Vv extension listens for the 'vv:rails:connect'
 * postMessage and forwards it to the background service worker.
 */

export function connectVv(options = {}) {
  const pageId =
    options.pageId ||
    document.body?.dataset?.pageId ||
    window.location.pathname;

  window.postMessage(
    {
      type: 'vv:rails:connect',
      url: options.cableUrl || '/cable',
      channel: options.channel || 'VvChannel',
      pageId,
    },
    '*',
  );
}

/**
 * Disconnect the Vv plugin from Rails.
 */
export function disconnectVv() {
  window.postMessage({ type: 'vv:rails:disconnect' }, '*');
}

// Auto-connect on DOMContentLoaded if data-vv-auto attribute is present on body.
// Usage: <body data-vv-auto>
document.addEventListener('DOMContentLoaded', () => {
  if (document.body?.dataset?.vvAuto !== undefined) {
    connectVv();
  }
});
