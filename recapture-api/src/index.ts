// src/index.ts
import '@/config/env'; // validates env first — import before anything else
import { connectDB } from '@/config/db';
import { createApp } from '@/app';
import { env } from '@/config/env';

async function main(): Promise<void> {
  await connectDB();
  const app = createApp();
  app.listen(env.PORT, () => {
    console.log(`🚀 recapture-api running on port ${env.PORT} [${env.NODE_ENV}]`);
  });
}

main().catch((err) => {
  console.error('Fatal startup error:', err);
  process.exit(1);
});
