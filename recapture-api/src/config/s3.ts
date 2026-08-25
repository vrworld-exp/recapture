// src/config/s3.ts
import { S3Client } from '@aws-sdk/client-s3';
import { env } from '@/config/env';

export const s3Client = new S3Client({
  region: env.AWS_REGION,
  credentials: {
    accessKeyId: env.AWS_ACCESS_KEY_ID,
    secretAccessKey: env.AWS_SECRET_ACCESS_KEY,
  },
});

// Bucket name constants — use these everywhere, never hardcode bucket names
export const BUCKET_RAW = env.S3_BUCKET_RAW; // msxr-raw-captures
export const BUCKET_ARTIFACTS = env.S3_BUCKET_ARTIFACTS; // msxr-model-artifacts
export const CLOUDFRONT_BASE = env.CLOUDFRONT_BASE_URL;
