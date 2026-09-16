// scripts/send-notification.ts
//
// Sends one in-app notification — the CLI door to POST /admin/notifications
// until a dashboard exists (see AGENTS.md "In-app notifications"). Goes through
// the SAME Zod schema and service as the route, so what this can send is
// exactly what the API can send, no more.
//
// Run with: npx tsx scripts/send-notification.ts --as <adminUserId> \
//             --title "Payment due" --message "Your plan renews on Friday." \
//             [--kind PAYMENT_DUE] [--detail "..."] \
//             [--action-label "Pay now" --action-url https://…|/catalog/analytics] \
//             [--to <userId>,<userId>]   (omit for a broadcast to everyone) \
//             [--expires 2026-10-01T00:00:00Z]
//
// Needs .env (MONGODB_URI etc. — same loader as the API). `--as` must be an
// ADMIN's user id: the actor is recorded (hashed) on the send event, and a
// non-admin id is refused here exactly as the route would refuse it.
import mongoose, { Types } from 'mongoose';
import { env } from '../src/config/env';
import { User, hasRoleAtLeast } from '../src/models/User';
import { createNotificationSchema } from '../src/validation/notificationSchemas';
import { createNotification } from '../src/services/notificationsService';

function parseArgs(argv: string[]): Map<string, string> {
  const out = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) {
      console.error(`Missing value for ${arg}`);
      process.exit(1);
    }
    out.set(arg.slice(2), value);
    i++;
  }
  return out;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const actorId = args.get('as');
  if (!actorId || !Types.ObjectId.isValid(actorId)) {
    console.error('Usage: npx tsx scripts/send-notification.ts --as <adminUserId> --title … --message … [options]');
    process.exit(1);
  }

  const to = args.get('to');
  const actionLabel = args.get('action-label');
  const actionUrl = args.get('action-url');
  if ((actionLabel === undefined) !== (actionUrl === undefined)) {
    console.error('--action-label and --action-url go together.');
    process.exit(1);
  }

  const body = createNotificationSchema.safeParse({
    ...(args.has('kind') ? { kind: args.get('kind') } : {}),
    title: args.get('title'),
    message: args.get('message'),
    ...(args.has('detail') ? { detail: args.get('detail') } : {}),
    ...(actionLabel !== undefined ? { action: { label: actionLabel, url: actionUrl } } : {}),
    audience: to
      ? { type: 'USERS', userIds: to.split(',').map((id) => id.trim()).filter(Boolean) }
      : { type: 'ALL' },
    ...(args.has('expires') ? { expiresAt: args.get('expires') } : {}),
  });
  if (!body.success) {
    console.error(`Invalid notification: ${body.error.issues[0]?.message ?? 'bad input'}`);
    process.exit(1);
  }

  await mongoose.connect(env.MONGODB_URI);
  try {
    const actor = await User.findById(actorId).select('role').exec();
    if (!actor || !hasRoleAtLeast(actor.role, 'ADMIN')) {
      console.error('--as must be the user id of an ADMIN.');
      process.exit(1);
    }

    const sent = await createNotification(body.data, actorId);
    const audience =
      sent.audience.type === 'ALL' ? 'everyone' : `${sent.audience.userIds.length} user(s)`;
    console.log(`Sent ${sent.kind} "${sent.title}" (id ${sent.id}) to ${audience}.`);
  } finally {
    await mongoose.disconnect();
  }
}

main().catch((err) => {
  console.error('send-notification failed:', err);
  process.exit(1);
});
