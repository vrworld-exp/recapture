import path from 'path';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  // `@/...` resolves to src/ for both the test files and the app code they import.
  resolve: {
    alias: { '@': path.resolve(__dirname, 'src') },
  },
  test: {
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    // First run of mongodb-memory-server may download a mongod binary.
    hookTimeout: 120_000,
    testTimeout: 30_000,
    // Applied to process.env BEFORE the app's module graph (and @/config/env,
    // which validates + freezes env at import) is loaded. NODE_ENV must be one of
    // the schema's values (development|staging|production) — NOT vitest's default
    // 'test' — and must stay non-production so analytics echoes to the console
    // sink the suite spies on. MONGODB_URI here is only a schema placeholder; the
    // suite connects mongoose to the ephemeral in-memory server instead.
    env: {
      NODE_ENV: 'development',
      MONGODB_URI: 'mongodb://127.0.0.1:27017/recapture-test-placeholder',
      JWT_SECRET: 'test-jwt-secret-at-least-32-characters-long-000',
      AWS_REGION: 'us-east-1',
      AWS_ACCESS_KEY_ID: 'test-access-key',
      AWS_SECRET_ACCESS_KEY: 'test-secret-key',
      S3_BUCKET_RAW: 'recapture-test-raw',
      S3_BUCKET_ARTIFACTS: 'recapture-test-artifacts',
      CLOUDFRONT_BASE_URL: 'https://test.cloudfront.net',
    },
  },
});
