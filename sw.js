// Version-stamped cache. Bump BUILD in assets/config.js on every deploy —
// a stale cached shell is the classic failure mode of GitHub Pages hosting.
const BUILD = '2026.08.24.2';
const CACHE = 'mdc-runs-v' + BUILD;

const SHELL = [
  './', './index.html', './run.html',
  './assets/app.css', './assets/api.js', './assets/config.js',
  './manifest.webmanifest'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

  // Never cache the API. The app keeps its own last-run copy in localStorage
  // so a failed fetch still shows this morning's stops.
  if (url.pathname.includes('/rest/v1/')) return;

  // Google Fonts: cache-first, they never change within a build
  if (url.hostname.endsWith('gstatic.com') || url.hostname.endsWith('googleapis.com')) {
    e.respondWith(caches.match(e.request).then(hit => hit || fetch(e.request).then(res => {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
      return res;
    }).catch(() => hit)));
    return;
  }

  if (e.request.method !== 'GET') return;

  // Shell: cache-first so the app opens instantly with no signal
  e.respondWith(
    caches.match(e.request).then(hit =>
      hit || fetch(e.request).catch(() => caches.match('./index.html')))
  );
});
