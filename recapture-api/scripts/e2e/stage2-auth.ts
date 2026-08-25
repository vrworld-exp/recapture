// scripts/e2e/stage2-auth.ts
//
// Live auth WITHOUT touching send-otp:
//   1. protected route with no token → 401 envelope
//   2. mint a test user + access token directly (same utils the API uses) → 200
//   3. mint a refresh-token record → POST /auth/refresh rotates it
//   4. replaying the OLD token → 401 AND burns the family (successor dies too)
//   5. mint a long-lived access token (for later stages) + a second user
import { randomUUID } from 'crypto';
import jwt from 'jsonwebtoken';
import { env } from '../../src/config/env';
import { User } from '../../src/models/User';
import { RefreshToken } from '../../src/models/RefreshToken';
import { signAccessToken, generateRefreshToken } from '../../src/utils/tokens';
import { connectDb, disconnectDb, loadState, saveState, check, finish, api } from './_shared';

async function mintUser(runTag: string, suffix: string): Promise<{ id: string; authUid: string }> {
  const authUid = `${runTag}_${suffix}`;
  const user = await User.findOneAndUpdate(
    { authUid },
    {
      $setOnInsert: {
        authProvider: 'custom',
        authUid,
        phone: `+9199999${Math.floor(10000 + Math.random() * 89999)}`,
        phoneVerified: true,
      },
    },
    { new: true, upsert: true }
  );
  return { id: user.id as string, authUid };
}

async function mintRefresh(userId: string): Promise<string> {
  const { token, tokenHash } = generateRefreshToken();
  await RefreshToken.create({
    tokenHash,
    userId,
    family: randomUUID(),
    rotatedFrom: null,
    expiresAt: new Date(Date.now() + env.REFRESH_TOKEN_TTL_SECONDS * 1000),
  });
  return token;
}

async function main(): Promise<void> {
  const state = loadState();
  await connectDb();

  // 1) no token → 401
  const noTok = await api('GET', '/projects');
  check('protected route without token → 401', noTok.status === 401, `got ${noTok.status}`);

  // 2) mint user + access token → 200
  const u1 = await mintUser(state.runTag, 'user1');
  const accessToken = signAccessToken({ sub: u1.id, userId: u1.id, authUid: u1.authUid });
  const withTok = await api('GET', '/projects', { token: accessToken });
  check(
    'protected route with minted token → 200 success envelope',
    withTok.status === 200 && withTok.body?.status === 'success',
    `got ${withTok.status}`
  );

  // 3) refresh rotation
  const rt1 = await mintRefresh(u1.id);
  const ref1 = await api('POST', '/auth/refresh', { body: { refreshToken: rt1 } });
  check(
    'POST /auth/refresh with valid token → 200 + new pair',
    ref1.status === 200 &&
      ref1.body?.status === 'success' &&
      typeof ref1.body?.accessToken === 'string' &&
      typeof ref1.body?.refreshToken === 'string' &&
      ref1.body.refreshToken !== rt1,
    `got ${ref1.status}`
  );
  const rt2: string | undefined = ref1.body?.refreshToken;
  const newAccess: string | undefined = ref1.body?.accessToken;

  const newAccessWorks = await api('GET', '/projects', { token: newAccess });
  check('refreshed access token works', newAccessWorks.status === 200);

  // 4) reuse detection: OLD token again → 401, and family burn kills rt2 too
  const reuse = await api('POST', '/auth/refresh', { body: { refreshToken: rt1 } });
  check('replaying rotated token → 401 generic', reuse.status === 401, `got ${reuse.status}`);
  const successorDead = await api('POST', '/auth/refresh', { body: { refreshToken: rt2 } });
  check(
    'family revoked: successor token also → 401',
    successorDead.status === 401,
    `got ${successorDead.status}`
  );

  // 5) long-lived access token for later stages + second user for ownership tests
  const longAccess = jwt.sign(
    { sub: u1.id, userId: u1.id, authUid: u1.authUid },
    env.JWT_SECRET,
    { expiresIn: 4 * 3600 }
  );
  const u2 = await mintUser(state.runTag, 'user2');
  const u2Access = jwt.sign(
    { sub: u2.id, userId: u2.id, authUid: u2.authUid },
    env.JWT_SECRET,
    { expiresIn: 4 * 3600 }
  );

  saveState({
    ...state,
    userId: u1.id,
    authUid: u1.authUid,
    accessToken: longAccess,
    user2Id: u2.id,
    user2AccessToken: u2Access,
  });

  await disconnectDb();
  finish();
}

main().catch((err) => {
  console.error('stage2 crashed:', err);
  process.exit(1);
});
