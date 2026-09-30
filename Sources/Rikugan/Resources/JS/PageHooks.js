// Rikugan page-world hooks (document-start, all frames). Kept deliberately small because it shares
// the page's JavaScript world: media request sniffing, SPA history events, optional console capture
// and site-permission-aware shims for geolocation, notifications and clipboard reads.
(function (cfg) {
  'use strict';
  if (!cfg || window.__rikuganHooksInstalled) return;
  Object.defineProperty(window, '__rikuganHooksInstalled', { value: true, enumerable: false });
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[cfg.handler];
  if (!handler) return;
  const postMessage = handler.postMessage.bind(handler);
  const post = (op, args) => postMessage({ ch: 'page', op, args: args || {} });
  const isTop = (() => { try { return window.top === window; } catch (_) { return false; } })();

  // ---- Media sniffing -------------------------------------------------------------------------------
  if (cfg.sniff) {
    const seen = new Set();
    const mediaRe = /\.(m3u8|mp4|m4v|webm|mov|mkv|mp3|m4a|aac|ogg|oga|opus|flac|wav|mpd|flv)(\?|#|$)/i;
    const report = (url, via, contentType) => {
      try {
        const abs = new URL(url, location.href).href;
        if (seen.has(abs) || abs.startsWith('blob:') || abs.startsWith('data:')) return;
        seen.add(abs);
        post('mediaFound', { url: abs, via, contentType: contentType || '' }).catch(() => {});
      } catch (_) {}
    };
    const isMediaType = (t) => /^(video|audio)\//i.test(t || '') || /mpegurl|dash\+xml/i.test(t || '');
    const origFetch = window.fetch;
    if (origFetch) {
      // Reported only once a response actually arrived: a request blocked by a content rule (DNR /
      // ad blocking) or failing on the network is never listed as downloadable media.
      window.fetch = function (input, init) {
        const url = typeof input === 'string' ? input : (input && input.url) || String(input);
        const p = origFetch.apply(this, arguments);
        p.then((r) => {
          try {
            const t = r.headers.get('content-type');
            if (isMediaType(t)) report(r.url || url, 'fetch', t);
            else if ((r.status > 0 || r.type === 'opaque') && mediaRe.test(r.url || url)) report(r.url || url, 'fetch', t);
          } catch (_) {}
        }, () => {});
        return p;
      };
    }
    const origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      try {
        const u = String(url);
        const xhr = this;
        let done = false;
        xhr.addEventListener('readystatechange', () => {
          if (done || xhr.readyState < 2 || xhr.status === 0) return;   // headers received; 0 = blocked / failed
          done = true;
          try {
            const t = xhr.getResponseHeader('content-type');
            const final = xhr.responseURL || u;
            if (isMediaType(t) || mediaRe.test(final)) report(final, 'xhr', t);
          } catch (_) {}
        });
      } catch (_) {}
      return origOpen.apply(this, arguments);
    };
  }

  // ---- SPA navigation events ---------------------------------------------------------------------------
  if (isTop) {
    const wrap = (name) => {
      const orig = history[name];
      history[name] = function () {
        const r = orig.apply(this, arguments);
        post('historyStateUpdated', { url: location.href, kind: name }).catch(() => {});
        return r;
      };
    };
    wrap('pushState'); wrap('replaceState');
    window.addEventListener('popstate', () => post('historyStateUpdated', { url: location.href, kind: 'popstate' }).catch(() => {}));
    window.addEventListener('hashchange', () => post('historyStateUpdated', { url: location.href, kind: 'hashchange' }).catch(() => {}));
  }

  // ---- Console capture (Web Inspector) --------------------------------------------------------------
  if (cfg.console) {
    const fmt = (v) => {
      if (typeof v === 'string') return v;
      if (v instanceof Error) return v.stack || String(v);
      try { return JSON.stringify(v, null, 1); } catch (_) { return String(v); }
    };
    for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
      const orig = console[level];
      console[level] = function (...args) {
        try { post('console', { level, text: args.map(fmt).join(' ').slice(0, 5000), url: location.href }).catch(() => {}); } catch (_) {}
        return orig.apply(this, args);
      };
    }
    window.addEventListener('error', (e) => post('console', { level: 'error', text: (e.message || 'Error') + ' @ ' + (e.filename || '') + ':' + (e.lineno || ''), url: location.href }).catch(() => {}));
    window.addEventListener('unhandledrejection', (e) => post('console', { level: 'error', text: 'Unhandled rejection: ' + fmt(e.reason), url: location.href }).catch(() => {}));
  }

  // ---- Geolocation (per-site permission) -------------------------------------------------------------
  if (cfg.geolocation && navigator.geolocation) {
    let watchSeq = 0;
    const watches = new Map();
    const toPosition = (r) => ({
      coords: { latitude: r.latitude, longitude: r.longitude, accuracy: r.accuracy, altitude: r.altitude, altitudeAccuracy: r.altitudeAccuracy, heading: r.heading, speed: r.speed },
      timestamp: r.timestamp,
    });
    const toError = (e) => ({ code: (e && e.code) || 2, message: String((e && e.message) || e), PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
    const request = (success, error, options) => {
      post('geolocation', { highAccuracy: !!(options && options.enableHighAccuracy) }).then((r) => {
        if (r && r.error) { if (error) error(toError(r)); } else if (success) success(toPosition(r));
      }, (e) => { if (error) error(toError(e)); });
    };
    const geo = {
      getCurrentPosition: (s, e, o) => request(s, e, o),
      watchPosition: (s, e, o) => {
        const id = ++watchSeq;
        request(s, e, o);
        watches.set(id, setInterval(() => request(s, e, o), 10000));
        return id;
      },
      clearWatch: (id) => { clearInterval(watches.get(id)); watches.delete(id); },
    };
    try { Object.defineProperty(Navigator.prototype, 'geolocation', { get: () => geo, configurable: true }); } catch (_) {}
  }

  // ---- Notifications ----------------------------------------------------------------------------------
  if (cfg.notifications) {
    let permission = cfg.notificationPermission || 'default';
    class RikuganNotification extends EventTarget {
      constructor(title, options) {
        super();
        this.title = String(title);
        this.body = (options && options.body) || '';
        this.tag = (options && options.tag) || '';
        this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null;
        if (permission !== 'granted') { setTimeout(() => { if (this.onerror) this.onerror(new Event('error')); }, 0); return; }
        const fail = () => { const ev = new Event('error'); if (this.onerror) this.onerror(ev); this.dispatchEvent(ev); };
        post('notify', { title: this.title, body: this.body, tag: this.tag }).then((r) => {
          if (r !== 'shown' && r !== 'clicked') {
            // Native refused (site or system permission): the page must not see a shown notification.
            if (r === 'denied') permission = 'denied';
            fail();
            return;
          }
          const shown = new Event('show'); if (this.onshow) this.onshow(shown); this.dispatchEvent(shown);
          if (r === 'clicked') { const ev = new Event('click'); if (this.onclick) this.onclick(ev); this.dispatchEvent(ev); }
        }).catch(fail);
      }
      close() { if (this.onclose) this.onclose(new Event('close')); }
      static get permission() { return permission; }
      static requestPermission(cb) {
        const p = post('notificationPermission', {}).then((r) => { permission = r || 'denied'; if (cb) cb(permission); return permission; });
        return p;
      }
    }
    RikuganNotification.maxActions = 0;
    try { Object.defineProperty(window, 'Notification', { value: RikuganNotification, configurable: true, writable: true }); } catch (_) {}
  }

  // ---- Clipboard read gate ------------------------------------------------------------------------------
  if (cfg.clipboardGate && navigator.clipboard) {
    const proto = Object.getPrototypeOf(navigator.clipboard);
    for (const name of ['readText', 'read']) {
      const orig = proto[name];
      if (typeof orig !== 'function') continue;
      proto[name] = function () {
        const self = this, args = arguments;
        return post('clipboardRead', {}).then((allowed) => {
          if (!allowed) throw new DOMException('Clipboard access denied by site settings', 'NotAllowedError');
          return orig.apply(self, args);
        });
      };
    }
  }
})(/*__RK_HOOKS_CONFIG__*/null);
