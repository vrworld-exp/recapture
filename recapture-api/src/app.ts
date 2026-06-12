// src/app.ts
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import { requestLogger } from '@/middleware/requestLogger';
import { errorHandler } from '@/middleware/errorHandler';
import { notFound } from '@/middleware/notFound';
import healthRouter from '@/routes/health';

export function createApp(): express.Express {
  const app = express();

  // Security + parsing
  app.use(helmet());
  app.use(cors());
  app.use(express.json({ limit: '1mb' }));
  app.use(express.urlencoded({ extended: true }));
  app.use(requestLogger);

  // Routes
  app.use('/health', healthRouter);

  // 404 + error handling — MUST be last
  app.use(notFound);
  app.use(errorHandler);

  return app;
}
