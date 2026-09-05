// scripts/repoint-catalog-owner.ts
//
// Moves a catalog (and everything hanging off its owner) from an orphan User to
// the correct one, then hard-deletes the orphan.
//
// WHY THIS EXISTS. A rep who mistypes the restaurant's phone at activation
// creates a real `User` row and binds the catalog to it. That row then holds the
// slot forever: the unique index is on `Catalog.userId` ALONE and it counts
// soft-deleted rows (src/models/Catalog.ts:139-141), so the owner can never
// activate or provision a second catalog under the right number. Nothing in the
// product can undo it — the activation is one-shot and `publicUrl` is frozen.
//
// A SCRIPT, NOT AN ENDPOINT — the same reasoning that keeps role grants
// script-only (see AGENTS.md "Roles"). This is rare, destructive, and wants a
// human who has already confirmed the correct number out of band.
//
// Run with: npx tsx scripts/repoint-catalog-owner.ts <catalogId> <phone> [--commit]
//   e.g.    npx tsx scripts/repoint-catalog-owner.ts 665f0c... +919876543210
//           npx tsx scripts/repoint-catalog-owner.ts 665f0c... +919876543210 --commit
//
// DRY RUN BY DEFAULT. Without --commit it prints the plan and changes nothing.
// Re-running after a partial failure is safe: every step is idempotent and keyed
// off the catalog, so a second run finishes whatever the first one left.
//
// Needs .env (MONGODB_URI etc. — same loader as the API). Never prints a raw
// phone back; identifiers go through the standard mask (PII rule).
import mongoose, { Types } from 'mongoose';
import { env } from '../src/config/env';
import { User } from '../src/models/User';
import { Catalog } from '../src/models/Catalog';
import { CatalogCategory } from '../src/models/CatalogCategory';
import { CatalogProduct } from '../src/models/CatalogProduct';
import { CatalogPublishRun } from '../src/models/CatalogPublishRun';
import { Project } from '../src/models/Project';
import { Job } from '../src/models/Job';
import { RefreshToken } from '../src/models/RefreshToken';
import { maskPhone } from '../src/utils/maskIdentifier';
import { phoneField } from '../src/validation/authSchemas';

/** Mask that always yields something printable, even for a degenerate phone. */
function mask(phone: string | null | undefined): string {
  if (!phone) return '(none)';
  return maskPhone(phone) ?? '•'.repeat(phone.length);
}

function usage(): never {
  console.error('Usage: npx tsx scripts/repoint-catalog-owner.ts <catalogId> <phone> [--commit]');
  console.error('  Without --commit this is a dry run and writes nothing.');
  process.exit(1);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const commit = args.includes('--commit');
  const [catalogIdArg, phoneArg] = args.filter((a) => a !== '--commit');
  if (!catalogIdArg || !phoneArg) usage();

  if (!Types.ObjectId.isValid(catalogIdArg)) {
    console.error(`Not a valid catalogId: ${JSON.stringify(catalogIdArg)}`);
    process.exit(1);
  }
  const catalogId = new Types.ObjectId(catalogIdArg);

  // The SAME normaliser the OTP and activation paths use. Parsing it here is the
  // whole point: '9876543210' and '+919876543210' must not become two accounts.
  const parsed = phoneField.safeParse(phoneArg);
  if (!parsed.success) {
    console.error(`Phone rejected: ${parsed.error.issues[0]?.message ?? 'invalid'}`);
    process.exit(1);
  }
  const phone = parsed.data;

  await mongoose.connect(env.MONGODB_URI);
  try {
    // Soft-deleted catalogs are in scope — a stranded one is exactly the case
    // this fixes, and it still occupies the owner's slot.
    const catalog = await Catalog.findById(catalogId).exec();
    if (!catalog) {
      console.error('No catalog matched that id.');
      process.exitCode = 1;
      return;
    }

    const orphanId = catalog.userId;
    const orphan = await User.findById(orphanId).exec();

    // Resolve-or-create the correct owner. Creating is normal: the restaurant
    // has usually never signed in, and the row created here is what their first
    // OTP will find and verify (verifyOtpService.resolveUser looks up by phone).
    let target = await User.findOne({ phone }).exec();
    const targetIsNew = !target;

    if (target && target.id === String(orphanId)) {
      console.log('Catalog already belongs to that phone — nothing to do.');
      return;
    }

    // The unique index on Catalog.userId is why this has to be checked up front:
    // a target who already owns a catalog cannot take a second one, and the
    // write would fail halfway through.
    if (target) {
      const existing = await Catalog.findOne({ userId: target._id }).exec();
      if (existing && String(existing._id) !== String(catalogId)) {
        console.error(
          `Target user ${target.id} already owns catalog ${String(existing._id)}. ` +
            'One catalog per user — repoint or retire that one first.'
        );
        process.exitCode = 1;
        return;
      }
    }

    // Refuse to delete an account somebody actually proved possession of. A
    // verified orphan is not an orphan; it is a real person, and this would be
    // deleting their account rather than a typo.
    if (orphan?.phoneVerified) {
      console.error(
        `Current owner ${orphan.id} (phone ${mask(orphan.phone)}) is phone-VERIFIED. ` +
          'That is a real account, not an activation typo — refusing to delete it.'
      );
      process.exitCode = 1;
      return;
    }
    if (orphan && orphan.role !== 'USER') {
      console.error(
        `Current owner ${orphan.id} holds role ${orphan.role} — refusing to delete a staff account.`
      );
      process.exitCode = 1;
      return;
    }

    // Counts drive the printed plan and double as the dry-run output.
    const [categories, products, runs, projects, jobs, tokens] = await Promise.all([
      CatalogCategory.countDocuments({ catalogId }).exec(),
      CatalogProduct.countDocuments({ catalogId }).exec(),
      CatalogPublishRun.countDocuments({ catalogId }).exec(),
      Project.countDocuments({ userId: orphanId }).exec(),
      Job.countDocuments({ userId: orphanId }).exec(),
      RefreshToken.countDocuments({ userId: orphanId }).exec(),
    ]);

    console.log('Plan:');
    console.log(
      `  catalog        ${String(catalogId)}${catalog.deletedAt ? ' (soft-deleted)' : ''}`
    );
    console.log(`  from owner     ${String(orphanId)} phone ${mask(orphan?.phone)}`);
    console.log(
      `  to owner       ${target ? target.id : '(will be created)'} phone ${mask(phone)}` +
        (targetIsNew ? '  [new, phoneVerified=false]' : '')
    );
    console.log(
      `  move           ${categories} categories, ${products} products, ${runs} publish runs`
    );
    console.log(`  move           ${projects} projects, ${jobs} jobs`);
    console.log(`  hard-delete    ${tokens} refresh tokens + the orphan user`);
    if (catalog.publicUrl) {
      console.log(`  publicUrl      ${catalog.publicUrl}  (UNTOUCHED — frozen)`);
    }

    if (!commit) {
      console.log('\nDry run — nothing written. Re-run with --commit to apply.');
      return;
    }

    if (!target) {
      target = await User.create({ phone, phoneVerified: false });
      console.log(`Created user ${target.id}.`);
    }
    const targetId = target._id;

    // Children first, catalog last. If this is interrupted the catalog still
    // points at the orphan, so a re-run picks up exactly where it stopped —
    // whereas moving the catalog first would leave nothing to key off.
    await CatalogCategory.updateMany({ catalogId }, { $set: { userId: targetId } }).exec();
    await CatalogProduct.updateMany({ catalogId }, { $set: { userId: targetId } }).exec();
    await CatalogPublishRun.updateMany({ catalogId }, { $set: { userId: targetId } }).exec();
    // Projects and jobs have no catalogId — they hang off the user. Every one the
    // orphan owns was created by this activation, so all of them move.
    await Project.updateMany({ userId: orphanId }, { $set: { userId: targetId } }).exec();
    await Job.updateMany({ userId: orphanId }, { $set: { userId: targetId } }).exec();
    await Catalog.updateOne({ _id: catalogId }, { $set: { userId: targetId } }).exec();

    // Hard delete, not soft: the whole point is to free the unique-index slot,
    // and a soft-deleted user would keep nothing useful — it owns no rows now.
    await RefreshToken.deleteMany({ userId: orphanId }).exec();
    await User.deleteOne({ _id: orphanId }).exec();

    console.log(`\nDone. Catalog ${String(catalogId)} now belongs to ${target.id} (${mask(phone)}).`);
    console.log('The owner signs in with the normal OTP flow; that flips phoneVerified.');
  } finally {
    await mongoose.disconnect();
  }
}

main().catch((err) => {
  console.error('repoint-catalog-owner failed:', err instanceof Error ? err.message : err);
  process.exit(1);
});
