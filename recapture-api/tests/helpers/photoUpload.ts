// tests/helpers/photoUpload.ts
//
// Shared fixtures for the five artist photo-upload suites. Only the setup that
// is genuinely identical across them lives here — each suite still owns its own
// MongoMemoryServer, its own S3 script and its own assertions, per the house
// pattern. Extracted because five copies of "make a MODEL_ARTIST and a project
// they own" is five places for the fixtures to drift out of sync with the
// schema.
import { Types } from 'mongoose';
import jwt from 'jsonwebtoken';

import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { Project } from '@/models/Project';

export interface TestUser {
  id: string;
  auth: { Authorization: string };
}

/** A real user document (requireRole does a fresh DB read) + its Bearer header. */
export async function makeUser(role?: UserRole): Promise<TestUser> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    ...(role ? { role } : {}),
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

/** An UPLOAD-source project: no objectSize, no mode — the conditional-required
 * path. Created through the model so the schema validators actually run. */
export async function makeUploadProject(ownerId: string, name = 'Brass Vase') {
  return Project.create({
    userId: new Types.ObjectId(ownerId),
    name,
    source: 'upload',
  });
}

/** An ordinary capture project, exactly as every pre-existing test makes one. */
export async function makeCaptureProject(ownerId: string, name = 'Carved Bowl') {
  return Project.create({
    userId: new Types.ObjectId(ownerId),
    name,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
}

/** N valid session file descriptors. */
export function files(count: number, contentType = 'image/jpeg', size = 1_000_000) {
  return Array.from({ length: count }, () => ({ contentType, size }));
}
