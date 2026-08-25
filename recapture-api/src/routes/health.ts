// src/routes/health.ts
import { Router } from 'express';
import mongoose from 'mongoose';

const router = Router();

router.get('/', (_req, res) => {
  const dbState = mongoose.connection.readyState;
  const dbStatus: Record<number, string> = {
    0: 'disconnected',
    1: 'connected',
    2: 'connecting',
    3: 'disconnecting',
  };
  res.status(200).json({
    status: 'ok',
    db: dbStatus[dbState] ?? 'unknown',
    timestamp: new Date().toISOString(),
    env: process.env.NODE_ENV,
  });
});

export default router;
