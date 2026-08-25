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

  it('serves a request with no Origin header (the mobile builds, curl)', async () => {
    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });
});
