// scripts/e2e/stage6-worker.ts
//
// Drives the Phase 6 worker modules (jobQueue claim/lease/retry, processor
// registry, queue depth) DETERMINISTICALLY against the real DB + real S3 —
// direct calls instead of a timing loop, since src/worker has no poll-loop
// entrypoint yet (recorded as a finding).
//
//   1. getQueueDepth sees the Stage 5 QUEUED job
//   2. claimNextJob → CLAIMED by us → markProcessing → stub CAPTURE_PROCESSING
//      processor (verifies the job's S3 objects, writes a real artifact to
//      msxr-model-artifacts) → markCompleted → COMPLETED + result persisted
//   3. nothing else claimable (UPLOADING job2 must NOT be picked up)
//   4. retry path: synthetic job whose processor throws → attempts=1, back to
//      QUEUED with future nextRetryAt (not claimable) → window forced open →
//      attempts=2=maxAttempts → terminal FAILED + structured error sub-doc
//   5. orphan recovery: synthetic PROCESSING job with a stale lease → re-claimed
import { Types } from 'mongoose';
import { PutObjectCommand } from '@aws-sdk/client-s3';
import { s3Client, BUCKET_ARTIFACTS } from '../../src/config/s3';
import { Job } from '../../src/models/Job';
import {
  claimNextJob,
  markProcessing,
  markCompleted,
  markFailed,
  getQueueDepth,
  jobTypeOf,
  PROCESSING_FAILED_CODE,
} from '../../src/worker/jobQueue';
import { registerProcessor, getProcessor } from '../../src/worker/processorRegistry';
import { DEFAULT_MAX_ATTEMPTS, type WorkerJob } from '../../src/worker/workerTypes';
import { objectExists, countObjectsUnderPrefix } from '../../src/services/s3ObjectStore';
import { connectDb, disconnectDb, loadState, saveState, check, finish } from './_shared';

const WORKER_ID = 'e2e-worker-1';
const CLAIM_TIMEOUT_MS = 120_000;

async function main(): Promise<void> {
  const state = loadState();
  await connectDb();
  const artifactKeys: string[] = [];

  // Stub CAPTURE_PROCESSING processor: verify this job's uploaded objects in
  // S3, then write a real artifact object — what the eventual photogrammetry
  // processor's contract looks like end-to-end.
  registerProcessor('CAPTURE_PROCESSING', async (job: WorkerJob) => {
    const { rawBucket, rawPrefix, manifestKey, expectedFilesCount } = job.upload!;
    const manifestOk = await objectExists(rawBucket, manifestKey);
    const count = await countObjectsUnderPrefix(rawBucket, rawPrefix);
    if (!manifestOk || count !== expectedFilesCount) {
      throw new Error(`input verification failed: manifest=${manifestOk} count=${count}`);
    }
    const artifactKey = `${rawPrefix}artifacts/e2e-model.json`;
    await s3Client.send(
      new PutObjectCommand({
        Bucket: BUCKET_ARTIFACTS,
        Key: artifactKey,
        Body: JSON.stringify({ jobId: job._id.toString(), verifiedFiles: count, e2e: true }),
      })
    );
    artifactKeys.push(artifactKey);
    return { artifactKey, verifiedFiles: count };
  });
  registerProcessor('E2E_FAILING', async () => {
    throw new Error('e2e simulated processing failure');
  });

  // 1) queue depth sees the Stage 5 job
  const depth0 = await getQueueDepth();
  check('getQueueDepth: QUEUED ≥ 1 before claim', (depth0['QUEUED'] ?? 0) >= 1, JSON.stringify(depth0));

  // 2) claim → process → complete the real job
  const claimed = await claimNextJob(WORKER_ID, CLAIM_TIMEOUT_MS);
  check(
    'claimNextJob claims the Stage 5 job (CLAIMED, claimedBy us)',
    claimed !== null &&
      claimed._id.toString() === state.jobId &&
      claimed.state === 'CLAIMED' &&
      claimed.claimedBy === WORKER_ID,
    claimed ? `${claimed._id} / ${claimed.state} / ${claimed.claimedBy}` : 'null'
  );

  if (claimed && claimed._id.toString() !== state.jobId) {
    // Never process a job this run didn't create — release and stop.
    await Job.updateOne(
      { _id: claimed._id },
      { $set: { state: 'QUEUED', claimedAt: null, claimedBy: null } }
    ).exec();
    console.log('  ⚠️ claimed a foreign job — released it and aborting stage');
    finish();
  }

  if (claimed) {
    await markProcessing(claimed._id);
    const mid = await Job.findById(claimed._id).exec();
    check('markProcessing → PROCESSING + startedAt', mid?.state === 'PROCESSING' && !!mid?.startedAt);

    const processor = getProcessor(jobTypeOf(claimed))!;
    check('processor registry resolves CAPTURE_PROCESSING', !!processor);
    try {
      const result = await processor(claimed);
      await markCompleted(claimed._id, result);
    } catch (err) {
      await markFailed(
        claimed._id,
        err as Error,
        (claimed.attempts ?? 0) + 1,
        claimed.maxAttempts ?? DEFAULT_MAX_ATTEMPTS
      );
    }
    const done = await Job.findById(claimed._id).exec();
    check(
      'job COMPLETED with persisted result',
      done?.state === 'COMPLETED' && (done?.result as any)?.verifiedFiles === 55,
      `${done?.state} / ${JSON.stringify(done?.result)}`
    );
    const artifactLanded =
      artifactKeys.length === 1 && (await objectExists(BUCKET_ARTIFACTS, artifactKeys[0]));
    check('artifact written to msxr-model-artifacts', artifactLanded, artifactKeys[0] ?? 'none');
  }

  // 3) UPLOADING job2 must not be claimable
  const nothing = await claimNextJob(WORKER_ID, CLAIM_TIMEOUT_MS);
  if (nothing) {
    await Job.updateOne(
      { _id: nothing._id },
      { $set: { state: 'QUEUED', claimedAt: null, claimedBy: null } }
    ).exec();
  }
  check('no further claimable job (UPLOADING job untouched)', nothing === null, nothing ? `claimed ${nothing._id}` : '');

  // 4) retry → backoff → terminal FAILED
  const failing = await Job.create({
    projectId: new Types.ObjectId(state.projectId!),
    userId: new Types.ObjectId(state.userId!),
    state: 'QUEUED',
    jobType: 'E2E_FAILING',
    maxAttempts: 2,
    queuedAt: new Date(),
  });
  const fclaim1 = await claimNextJob(WORKER_ID, CLAIM_TIMEOUT_MS);
  check('failing job claimed', fclaim1?._id.toString() === failing.id, fclaim1?._id.toString());
  if (fclaim1) {
    await markProcessing(fclaim1._id);
    try {
      await getProcessor(jobTypeOf(fclaim1))!(fclaim1);
    } catch (err) {
      await markFailed(fclaim1._id, err as Error, (fclaim1.attempts ?? 0) + 1, fclaim1.maxAttempts ?? 3);
    }
  }
  const afterFail1 = await Job.findById(failing.id).exec();
  check(
    'attempt 1 → back to QUEUED, attempts=1, future nextRetryAt, lease cleared',
    afterFail1?.state === 'QUEUED' &&
      afterFail1?.attempts === 1 &&
      afterFail1!.nextRetryAt!.getTime() > Date.now() &&
      afterFail1?.claimedAt === null &&
      afterFail1?.claimedBy === null,
    `${afterFail1?.state}/attempts=${afterFail1?.attempts}`
  );
  const backoffClosed = await claimNextJob(WORKER_ID, CLAIM_TIMEOUT_MS);
  check('backoff respected: not claimable before nextRetryAt', backoffClosed === null);

  await Job.updateOne({ _id: failing._id }, { $set: { nextRetryAt: new Date(Date.now() - 1000) } }).exec();
  const fclaim2 = await claimNextJob(WORKER_ID, CLAIM_TIMEOUT_MS);
  check('claimable again once retry window opens', fclaim2?._id.toString() === failing.id);
  if (fclaim2) {
    await markProcessing(fclaim2._id);
    try {
      await getProcessor(jobTypeOf(fclaim2))!(fclaim2);
    } catch (err) {
      await markFailed(fclaim2._id, err as Error, (fclaim2.attempts ?? 0) + 1, fclaim2.maxAttempts ?? 3);
    }
  }
  const afterFail2 = await Job.findById(failing.id).exec();
  check(
    'attempts exhausted → terminal FAILED + structured error sub-doc',
    afterFail2?.state === 'FAILED' &&
      afterFail2?.attempts === 2 &&
      afterFail2?.error?.code === PROCESSING_FAILED_CODE &&
      afterFail2?.nextRetryAt === null,
    `${afterFail2?.state}/attempts=${afterFail2?.attempts}/error=${afterFail2?.error?.code}`
  );
  const failedNotClaimable = await claimNextJob(WORKER_ID, CLAIM_TIMEOUT_MS);
  check('FAILED job never claimable again', failedNotClaimable === null);

  // 5) orphan recovery: stale PROCESSING lease from a dead worker
  const orphan = await Job.create({
    projectId: new Types.ObjectId(state.projectId!),
    userId: new Types.ObjectId(state.userId!),
    state: 'PROCESSING',
    jobType: 'E2E_FAILING', // type irrelevant; only the claim matters
    claimedAt: new Date(Date.now() - 10 * 60 * 1000),
    claimedBy: 'dead-worker-e2e',
  });
  const reclaimed = await claimNextJob(WORKER_ID, 5 * 60 * 1000);
  check(
    'stale-lease PROCESSING job re-claimed by a live worker',
    reclaimed?._id.toString() === orphan.id && reclaimed?.claimedBy === WORKER_ID,
    reclaimed ? `${reclaimed._id}/${reclaimed.claimedBy}` : 'null'
  );
  if (reclaimed) {
    // Park it COMPLETED so it can't interfere with later claims; cleanup deletes it.
    await markCompleted(reclaimed._id, { e2e: 'orphan-reclaim-proven' });
  }

  const depthEnd = await getQueueDepth();
  check(
    'getQueueDepth reports per-state counts (COMPLETED & FAILED present)',
    (depthEnd['COMPLETED'] ?? 0) >= 1 && (depthEnd['FAILED'] ?? 0) >= 1,
    JSON.stringify(depthEnd)
  );

  saveState({
    ...state,
    artifactKeys,
    extraJobIds: [failing.id as string, orphan.id as string],
  });
  await disconnectDb();
  finish();
}

main().catch((err) => {
  console.error('stage6 crashed:', err);
  process.exit(1);
});
