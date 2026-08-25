// scripts/e2e/stage5b-plan-expiry.ts
//
// Re-test the plan-window 410: backdate job2.createdAt via the RAW collection
// (mongoose drops $set on immutable createdAt), initiate → expect 410, restore.
import { Types } from 'mongoose';
import { Job } from '../../src/models/Job';
import { connectDb, disconnectDb, loadState, check, finish, api } from './_shared';

async function main(): Promise<void> {
  const state = loadState();
  const tok = state.accessToken!;
  const jobId = state.badJobId as string;
  const keyPrefix = state.job2RootPrefix as string;
  await connectDb();

  const _id = new Types.ObjectId(jobId);
  const original = await Job.collection.findOne({ _id });
  const realCreatedAt = original!.createdAt as Date;

  await Job.collection.updateOne(
    { _id },
    { $set: { createdAt: new Date(Date.now() - 25 * 3600 * 1000) } }
  );
  const expired = await api('POST', `/jobs/${jobId}/uploads/initiate`, {
    token: tok,
    body: { key: `${keyPrefix}images/EYE/expiry-probe.jpg`, fileSize: 1024, partCount: 1 },
  });
  check(
    'initiate after plan window → 410 PLAN_EXPIRED',
    expired.status === 410 && expired.body?.code === 'PLAN_EXPIRED',
    `got ${expired.status}/${expired.body?.code}`
  );
  await Job.collection.updateOne({ _id }, { $set: { createdAt: realCreatedAt } });

  await disconnectDb();
  finish();
}

main().catch((err) => {
  console.error('stage5b crashed:', err);
  process.exit(1);
});
