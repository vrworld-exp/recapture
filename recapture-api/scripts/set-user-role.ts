// scripts/set-user-role.ts
//
// Flips a user's access role — the ONLY grant path (no grant UI or endpoint
// exists by design; see AGENTS.md "Roles").
//
// Run with: npx tsx scripts/set-user-role.ts <phone-or-userId> <role>
//   e.g.    npx tsx scripts/set-user-role.ts +919876543210 MODEL_ARTIST
//           npx tsx scripts/set-user-role.ts 665f0c... ADMIN
//
// Needs .env (MONGODB_URI etc. — same loader as the API). Never prints the raw
// phone back; identifiers are masked (PII rule).
import mongoose, { Types } from 'mongoose';
import { env } from '../src/config/env';
import { User, USER_ROLES, type UserRole } from '../src/models/User';

/** Masks a phone for terminal output: first 3 + last 2 chars survive. */
function maskPhone(phone: string): string {
  if (phone.length <= 5) return '•'.repeat(phone.length);
  return `${phone.slice(0, 3)}${'•'.repeat(phone.length - 5)}${phone.slice(-2)}`;
}

async function main(): Promise<void> {
  const [identifier, roleArg] = process.argv.slice(2);
  if (!identifier || !roleArg) {
    console.error('Usage: npx tsx scripts/set-user-role.ts <phone-or-userId> <role>');
    console.error(`  role: one of ${USER_ROLES.join(' | ')}`);
    process.exit(1);
  }

  const role = roleArg.toUpperCase();
  if (!(USER_ROLES as readonly string[]).includes(role)) {
    console.error(`Unknown role ${JSON.stringify(roleArg)} — expected ${USER_ROLES.join(' | ')}`);
    process.exit(1);
  }

  await mongoose.connect(env.MONGODB_URI);
  try {
    // A 24-hex identifier is treated as a userId; anything else as a phone.
    const filter = Types.ObjectId.isValid(identifier)
      ? { _id: new Types.ObjectId(identifier) }
      : { phone: identifier.trim() };

    const user = await User.findOneAndUpdate(
      filter,
      { $set: { role: role as UserRole } },
      { new: true, runValidators: true }
    ).exec();

    if (!user) {
      console.error('No user matched that identifier.');
      process.exitCode = 1;
      return;
    }

    const who = user.phone ? ` (phone ${maskPhone(user.phone)})` : '';
    console.log(`Updated user ${user.id}${who} → role ${user.role}`);
  } finally {
    await mongoose.disconnect();
  }
}

main().catch((err) => {
  console.error('set-user-role failed:', err instanceof Error ? err.message : err);
  process.exit(1);
});
