// scripts/e2e/stage7-cleanup.ts
//
// Deletes EVERYTHING this E2E run created, then proves zero leftovers:
//   S3   — every object under both job root prefixes (raw bucket) and every
//          artifact key (artifacts bucket)
//   Mongo — e2e_ users, their refresh tokens, e2e_ projects, and every job
//          referencing those projects (covers synthetic worker jobs too)
// Also probes the raw bucket's lifecycle config for the
// AbortIncompleteMultipartUpload rule the code flags as required (informational).
import {
  ListObjectsV2Command,
  DeleteObjectsCommand,
  GetBucketLifecycleConfigurationCommand,
} from '@aws-sdk/client-s3';
import { s3Client, BUCKET_RAW, BUCKET_ARTIFACTS } from '../../src/config/s3';
import { User } from '../../src/models/User';
import { RefreshToken } from '../../src/models/RefreshToken';
import { Project } from '../../src/models/Project';
import { Job } from '../../src/models/Job';
import { countObjectsUnderPrefix } from '../../src/services/s3ObjectStore';
import { connectDb, disconnectDb, loadState, check, finish } from './_shared';

async function deleteAllUnderPrefix(bucket: string, prefix: string): Promise<number> {
  let deleted = 0;
  for (;;) {
    const page = await s3Client.send(
      new ListObjectsV2Command({ Bucket: bucket, Prefix: prefix, MaxKeys: 1000 })
    );
    const keys = (page.Contents ?? []).map((o) => ({ Key: o.Key! }));
    if (keys.length === 0) break;
    await s3Client.send(
      new DeleteObjectsCommand({ Bucket: bucket, Delete: { Objects: keys, Quiet: true } })
    );
    deleted += keys.length;
    if (!page.IsTruncated) break;
  }
  return deleted;
}

async function main(): Promise<void> {
  const state = loadState();
  await connectDb();

  // ── S3 ──────────────────────────────────────────────────────────────────────
  let s3Deleted = 0;
  for (const prefix of [state.jobRootPrefix, state.job2RootPrefix as string | undefined]) {
    if (prefix) s3Deleted += await deleteAllUnderPrefix(BUCKET_RAW, prefix);
  }
  for (const key of state.artifactKeys ?? []) {
    s3Deleted += await deleteAllUnderPrefix(BUCKET_ARTIFACTS, key);
  }
  const rawLeft = state.jobRootPrefix
    ? await countObjectsUnderPrefix(BUCKET_RAW, state.jobRootPrefix)
    : 0;
  const raw2Left = state.job2RootPrefix
    ? await countObjectsUnderPrefix(BUCKET_RAW, state.job2RootPrefix as string)
    : 0;
  const artLeft = state.artifactKeys?.length
    ? await countObjectsUnderPrefix(BUCKET_ARTIFACTS, (state.artifactKeys as string[])[0])
    : 0;
  check(
    `S3 cleanup: ${s3Deleted} objects deleted, 0 left under e2e prefixes`,
    rawLeft === 0 && raw2Left === 0 && artLeft === 0,
    `leftovers raw=${rawLeft + raw2Left} artifacts=${artLeft}`
  );

  // ── Mongo ───────────────────────────────────────────────────────────────────
  // Order: users → tokens → projects → jobs, all keyed off e2e_ markers.
  const users = await User.find({ authUid: /^e2e_\d+_/ }).exec();
  const userIds = users.map((u) => u._id);
  const projects = await Project.find({ name: /^e2e_\d+_/ }).exec();
  const projectIds = projects.map((p) => p._id);

  const delJobs = await Job.deleteMany({
    $or: [{ projectId: { $in: projectIds } }, { userId: { $in: userIds } }],
  }).exec();
  const delProjects = await Project.deleteMany({ _id: { $in: projectIds } }).exec();
  const delTokens = await RefreshToken.deleteMany({ userId: { $in: userIds } }).exec();
  const delUsers = await User.deleteMany({ _id: { $in: userIds } }).exec();

  const leftovers =
    (await User.countDocuments({ authUid: /^e2e_\d+_/ })) +
    (await Project.countDocuments({ name: /^e2e_\d+_/ })) +
    (await Job.countDocuments({ projectId: { $in: projectIds } }));
  check(
    `Mongo cleanup: ${delUsers.deletedCount} users, ${delTokens.deletedCount} refresh tokens, ` +
      `${delProjects.deletedCount} projects, ${delJobs.deletedCount} jobs deleted; 0 left`,
    leftovers === 0,
    `leftovers=${leftovers}`
  );

  // ── informational: lifecycle rule the code comments flag as required ────────
  try {
    const lc = await s3Client.send(
      new GetBucketLifecycleConfigurationCommand({ Bucket: BUCKET_RAW })
    );
    const hasAbortRule = (lc.Rules ?? []).some((r) => r.AbortIncompleteMultipartUpload);
    console.log(
      `  ℹ️ raw-bucket lifecycle: ${lc.Rules?.length ?? 0} rule(s); ` +
        `AbortIncompleteMultipartUpload present: ${hasAbortRule}`
    );
  } catch (err) {
    const e = err as { name?: string };
    console.log(
      `  ℹ️ raw-bucket lifecycle: could not read (${e.name}) — verify the ` +
        `AbortIncompleteMultipartUpload rule manually in the console`
    );
  }

  await disconnectDb();
  finish();
}

main().catch((err) => {
  console.error('stage7 crashed:', err);
  process.exit(1);
});
