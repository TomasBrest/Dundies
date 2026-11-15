// Service worker – appka funguje aj bez internetu (okrem nových dlaždíc mapy)
const VERSION = 'spomienky-v4';
const TILES = 'spomienky-tiles';
const MAX_TILES = 2000;

const SHELL = [
  './',
  './index.html',
  './manifest.json',
  './icons/favicon.png',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/apple-touch-icon.png',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION && k !== TILES).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

async function trimTiles() {
  const c = await caches.open(TILES);
  const keys = await c.keys();
  if (keys.length > MAX_TILES) {
    await Promise.all(keys.slice(0, keys.length - MAX_TILES).map(k => c.delete(k)));
  }
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Vyhľadávanie miest – vždy z internetu
  if (url.hostname.includes('nominatim')) return;

  // Dlaždice mapy – najprv z cache, potom z internetu
  if (url.hostname.endsWith('basemaps.cartocdn.com')) {
    e.respondWith(
      caches.open(TILES).then(async c => {
        const hit = await c.match(req);
        if (hit) return hit;
        const res = await fetch(req);
        if (res.ok || res.type === 'opaque') {
          c.put(req, res.clone());
          trimTiles();
        }
        return res;
      })
    );
    return;
  }

  // Appka samotná – z cache a na pozadí sa aktualizuje
  e.respondWith(
    caches.open(VERSION).then(async c => {
      const hit = await c.match(req, { ignoreSearch: true });
      const net = fetch(req).then(res => {
        if (res.ok) c.put(req, res.clone());
        return res;
      }).catch(() => hit);
      return hit || net;
    })
  );
});
