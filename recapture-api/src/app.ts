// src/app.ts
import express from 'express';
import cors, { type CorsOptions } from 'cors';
import helmet from 'helmet';
import { env } from '@/config/env';
import { requestLogger } from '@/middleware/requestLogger';
import { errorHandler } from '@/middleware/errorHandler';
import { notFound } from '@/middleware/notFound';
import healthRouter from '@/routes/health';
import authRouter from '@/routes/auth';
import projectsRouter from '@/routes/projects';
import jobsRouter from '@/routes/jobs';
import catalogRouter from '@/routes/catalog';
import remoteConfigRouter from '@/routes/remoteConfig';
import adminRouter from '@/routes/admin';

/** `flutter run -d chrome` binds a fresh random port each launch. */
const LOCALHOST_ORIGIN = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

function isAllowedOrigin(origin: string): boolean {
  if (env.CORS_ALLOWED_ORIGINS.includes(origin)) return true;
  return env.NODE_ENV !== 'production' && LOCALHOST_ORIGIN.test(origin);
}

/**
 * Explicit allowlist (CORS_ALLOWED_ORIGINS) rather than the reflect-everything
 * default. Auth rides in the Authorization header, never in a cookie, so
 * `credentials` stays off — no origin gets to make an ambient-authority call.
 */
const corsOptions: CorsOptions = {
  origin(origin, callback) {
    // No Origin header ⇒ not a browser cross-origin request (the mobile app,
    // curl, server-to-server). CORS has nothing to say about it.
    if (!origin) return callback(null, true);
    // A disallowed origin is answered WITHOUT the CORS headers rather than
    // with an error: the browser blocks it, and the API's own error envelope
    // is never replaced by a cors throw.
    callback(null, isAllowedOrigin(origin));
  },
  credentials: false,
};

export function createApp(): express.Express {
  const app = express();

  // Security + parsing
  app.use(helmet());
  app.use(cors(corsOptions));
  app.use(express.json({ limit: '1mb' }));
  app.use(express.urlencoded({ extended: true }));
  app.use(requestLogger);

  // Routes
  app.use('/health', healthRouter);
  app.use('/auth', authRouter);
  app.use('/projects', projectsRouter);
  app.use('/jobs', jobsRouter);
  // Catalog authoring (requireAuth inside the router). Owner-scoped: every
  // route resolves the caller's single catalog from the token.
  app.use('/catalog', catalogRouter);
  // Public (no JWT) — consumed at client startup, possibly pre-login.
  app.use('/remote-config', remoteConfigRouter);
  // Staff-only (requireAuth + requireRole ≥ MODEL_ARTIST inside the router).
  app.use('/admin', adminRouter);

  // 404 + error handling — MUST be last
  app.use(notFound);
  app.use(errorHandler);

  return app;
}
