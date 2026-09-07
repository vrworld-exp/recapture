// scripts/mint-dev-qr-batch.ts
//
// Mints a batch of standee codes straight against the database, bypassing
// POST /admin/qr-batches — so a dev can get a usable code without first
// flipping their own account to ADMIN and back (see set-user-role.ts, the only
// grant path). The real print run always goes through the admin endpoint; this
// exists so the rep activation flow is testable on a fresh database.
//
// Run with: npx tsx scripts/mint-dev-qr-batch.ts [count] [label]
//   e.g.    npx tsx scripts/mint-dev-qr-batch.ts 10 dev-test
//
// Refuses to run when NODE_ENV is production: minting there commits the
// business to a physical print run and must carry a real admin's id.
import mongoose, { Types } from 'mongoose';
import { env } from '../src/config/env';
import { mintBatch } from '../src/services/qrCodeService';
import { QrCode } from '../src/models/QrCode';
import { User } from '../src/models/User';

async function main(): Promise<void> {
  if (env.NODE_ENV === 'production') {
    console.error('Refusing to run in production — use POST /admin/qr-batches.');
    process.exit(1);
  }

  const count = Number(process.argv[2] ?? 10);
  const label = process.argv[3] ?? 'dev-test';
  if (!Number.isInteger(count) || count < 1 || count > env.QR_BATCH_MAX_SIZE) {
    console.error(`count must be a whole number between 1 and ${env.QR_BATCH_MAX_SIZE}`);
    process.exit(1);
  }

  await mongoose.connect(env.MONGODB_URI);
  try {
    // createdByUserId is required and refs User. Prefer a real admin so the
    // batch reads like one the endpoint would have produced; fall back to a
    // synthetic id rather than failing, since dev databases often have none.
    const admin = await User.findOne({ role: 'ADMIN' }).select('_id').exec();
    const createdByUserId = (admin?._id as Types.ObjectId) ?? new Types.ObjectId();
    if (!admin) console.warn('No ADMIN user found — attributing the batch to a synthetic id.');

    const { batchId, minted } = await mintBatch({ count, label, createdByUserId });

    const codes = await QrCode.find({ batchId }).select('code').lean().exec();
    const base = env.PUBLIC_RESOLVER_BASE_URL;

    console.log(`\nbatchId ${batchId.toString()} — minted ${minted} (label ${JSON.stringify(label)})\n`);
    for (const { code } of codes) {
      console.log(base ? `${code}  ${base}/r/${code}` : code);
    }
    if (!base) {
      console.warn('\nPUBLIC_RESOLVER_BASE_URL is unset — codes exist, but activation will');
      console.warn('answer RESOLVER_NOT_CONFIGURED until you set it in .env.');
    }
  } finally {
    await mongoose.disconnect();
  }
}

main().catch((err) => {
  console.error('mint-dev-qr-batch failed:', err instanceof Error ? err.message : err);
  process.exit(1);
});
