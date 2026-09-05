// tests/cors.test.ts
//
// The origin allowlist in src/app.ts. Hermetic: /health touches no database
// (it only reads mongoose.connection.readyState), so the whole suite runs
// against a bare createApp() with no in-memory mongod.
//
// CORS_ALLOWED_ORIGINS is left unset here on purpose — these assertions pin the
// schema DEFAULT (the deployed web client), which is what an environment that
// forgets to set the var will actually serve.
import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { createApp } from '@/app';

const app = createApp();
const WEB_CLIENT = 'https://recapture-live.onrender.com';

describe('CORS allowlist', () => {
  it('reflects an allowlisted origin', async () => {
    const res = await request(app).get('/health').set('Origin', WEB_CLIENT);

    expect(res.status).toBe(200);
    expect(res.headers['access-control-allow-origin']).toBe(WEB_CLIENT);
  });

  it('answers the preflight for an authenticated call from the web client', async () => {
    const res = await request(app)
      .options('/projects')
      .set('Origin', WEB_CLIENT)
      .set('Access-Control-Request-Method', 'GET')
      .set('Access-Control-Request-Headers', 'authorization,content-type');

    expect(res.status).toBe(204);
    expect(res.headers['access-control-allow-origin']).toBe(WEB_CLIENT);
    expect(res.headers['access-control-allow-headers']).toContain('authorization');
  });

  it('omits the CORS headers for an origin that is not allowlisted', async () => {
    const res = await request(app).get('/health').set('Origin', 'https://not-ours.example.com');

    // Answered normally — the BROWSER blocks it on the missing header, and the
    // API never swaps its own response for a cors error.
    expect(res.status).toBe(200);
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });

  it('allows localhost on any port outside production (flutter run -d chrome)', async () => {
    // vitest.config.ts pins NODE_ENV=development for the whole suite.
    const res = await request(app).get('/health').set('Origin', 'http://localhost:52341');

    expect(res.headers['access-control-allow-origin']).toBe('http://localhost:52341');
  });

  // ── Exposed response headers ──────────────────────────────────────────────
  //
  // A browser cannot READ a response header unless it is exposed, even on an
  // allowed origin — and the failure is SILENT: the download still happens, it
  // is just named "export" with no extension. Nothing in the client can detect
  // it, so it is pinned here.

  it('exposes Content-Disposition, so a browser download keeps its filename', async () => {
    const res = await request(app).get('/health').set('Origin', WEB_CLIENT);

    const exposed = res.headers['access-control-expose-headers'] ?? '';
    // Both consumers of this: the QR PNG/PDF download (matrix row 9, row 22)
    // and the admin QR batch CSV export (row 23).
    expect(exposed).toContain('Content-Disposition');
  });

  it('exposes ETag, so the QR render can be conditionally re-fetched', async () => {
    const res = await request(app).get('/health').set('Origin', WEB_CLIENT);

    expect(res.headers['access-control-expose-headers'] ?? '').toContain('ETag');
  });

  it('answers the preflight for the QR batch CSV export', async () => {
    // The export is a GET behind a Bearer token, so the browser preflights it.
    const res = await request(app)
      .options('/admin/qr-batches/000000000000000000000000/export')
      .set('Origin', WEB_CLIENT)
      .set('Access-Control-Request-Method', 'GET')
      .set('Access-Control-Request-Headers', 'authorization');

    expect(res.status).toBe(204);
    expect(res.headers['access-control-allow-origin']).toBe(WEB_CLIENT);
    expect(res.headers['access-control-allow-headers']).toContain('authorization');
  });

  it('serves a request with no Origin header (the mobile builds, curl)', async () => {
    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });
});
