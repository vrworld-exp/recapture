# Stage 1 — Foundations

**Side:** backend + client · **Size:** S (≈ ½ day) · **Depends on:** nothing

---

## Goal

At the end of this stage the `SALES_REP` role exists on both sides of the wire, the new
configuration is validated at boot, and the client's staff gate no longer mistakes a rep for staff.
**Nothing behaves differently yet** — no route reads the role, no code path branches on it. This
stage exists so that stages 2–6 never have to touch `User.ts`, `env.ts` or `user_role.dart` again,
and so the one genuinely dangerous edit (`isStaff`) lands alone where a reviewer can see it.

Ship this on its own. It is inert in production.

---

## Prerequisites

- The preflight checklist in [`00-preflight-and-corrections.md`](00-preflight-and-corrections.md)
  is green.
- You have read corrections **C2**, **C4** and **C5** — all three are about this stage.

---

## Verified context

| Fact | Where |
|---|---|
| `USER_ROLES = ['USER', 'MODEL_ARTIST', 'ADMIN']` | `recapture-api/src/models/User.ts:13` |
| `ROLE_RANK` is module-private, read only by `hasRoleAtLeast` | `src/models/User.ts:16-21` |
| `hasRoleAtLeast` has exactly one caller | `src/middleware/requireRole.ts:47` |
| `requireRole` re-reads the role from the DB on every request — it is deliberately **not** a JWT claim | `src/middleware/requireRole.ts:29-33` |
| `scripts/set-user-role.ts` derives its accepted set from `USER_ROLES` | `scripts/set-user-role.ts:14, 31` |
| `analyticsSchemas.ts` does `z.enum(USER_ROLES)` for the admin actor-role prop | `src/validation/analyticsSchemas.ts:17` |
| Dart `UserRole` is `user, modelArtist, admin` with `isStaff => this != user` | `lib/domain/entities/user_role.dart:11-19` |

---

## Steps

### 1. Add `SALES_REP` to the role ladder

**File:** `recapture-api/src/models/User.ts`

```ts
export const USER_ROLES = ['USER', 'SALES_REP', 'MODEL_ARTIST', 'ADMIN'] as const;
export type UserRole = (typeof USER_ROLES)[number];

const ROLE_RANK: Record<UserRole, number> = {
  USER: 0,
  SALES_REP: 1,
  MODEL_ARTIST: 2,
  ADMIN: 3,
};
```

Update the doc comment above `USER_ROLES` so the inclusion chain it states is the real one:
`ADMIN ⊇ MODEL_ARTIST ⊇ SALES_REP ⊇ USER`.

**Write the accepted consequence into the comment, not just into this document.** Privilege is
inclusive upward, so **every `MODEL_ARTIST` and `ADMIN` passes every rep gate**, including
activating and repointing QR codes. That is tolerable because both are trusted roles granted only
by `scripts/set-user-role.ts` with no grant UI — but it must be a stated decision in the file a
future reader opens, not folklore. Add:

```
 * SALES_REP sits at rank 1: a rep is trusted with act-on-behalf-of writes but
 * with none of the staff surfaces. Note the upward inclusion is REAL here —
 * MODEL_ARTIST and ADMIN both pass every /rep gate. That is accepted, not
 * overlooked: both are script-granted trusted roles, and every acting-on-behalf
 * write leaves a CatalogDelegation row, so the inheritance is auditable.
```

The schema `enum: USER_ROLES` and the `default: 'USER'` at `:99-104` are unchanged and need no
migration — a pre-existing document without the field still materialises as `USER`.

Per **C4**, do not go looking for rank call sites. There are none outside this file.

### 2. Confirm the role script picked it up — do not edit it

**File:** `recapture-api/scripts/set-user-role.ts` — **no change**

Per **C2**, it reads `USER_ROLES`. Prove it rather than assuming:

```bash
cd recapture-api
npx tsx scripts/set-user-role.ts 2>&1 | head -3
# usage line must now read: role: one of USER | SALES_REP | MODEL_ARTIST | ADMIN
```

If that line does not include `SALES_REP`, step 1 is wrong — fix step 1, do not patch the script.

### 3. Add the stage's configuration, all in one commit

**Files:** `recapture-api/src/config/env.ts` **and** `recapture-api/.env.example`

House rule: both files change together, or neither does. Follow the existing Zod shapes at
`env.ts:417-458` — tunables get defaults, secrets get none.

```ts
  /**
   * Origin the pre-printed standees encode: a code resolves at
   * `{PUBLIC_RESOLVER_BASE_URL}/r/{code}`. Written verbatim into
   * `catalog.publicUrl` at activation and then FROZEN, so changing this value
   * later does NOT repoint already-printed codes — it only affects codes minted
   * after the change. Treat it as append-only in production.
   */
  PUBLIC_RESOLVER_BASE_URL: z.string().url().optional(),

  /** Largest single mint. Bounds one bad admin request, not total inventory. */
  QR_BATCH_MAX_SIZE: z.coerce.number().int().positive().max(10_000).default(2_000),

  /** Per-rep activation rate window — see utils/rateLimit.ts. */
  ACTIVATION_MAX_PER_WINDOW: z.coerce.number().int().positive().default(30),
  ACTIVATION_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),
```

`PUBLIC_RESOLVER_BASE_URL` is `.optional()` rather than defaulted **on purpose**: an environment
that has not set it must not silently mint codes pointing at a guessed host. Stage 2's mint
endpoint and stage 4's activation both fail loudly when it is absent. The API still boots without
it, so stages 1–3 can deploy before the public hostname is decided.

Mirror all four into `.env.example` with the same comments, values left blank for the URL.

### 4. Fix the client staff gate — the dangerous edit

**File:** `lib/domain/entities/user_role.dart`

Per **C5**, grep first:

```bash
cd "d:/ASHISH_K3/VR World Code 2/phase2/ReCapture"
grep -rn "UserRole\." lib/ test/ | grep -i "index"
```

Expect **no** hits. If there are hits, stop and append `salesRep` last with an explicit `rank`
getter instead of the ordering below.

With no hits, insert in ladder order so the enum reads as the ladder it mirrors:

```dart
enum UserRole {
  user,
  salesRep,
  modelArtist,
  admin;

  /// True for roles that unlock the staff-only surfaces (the Live projects
  /// tab, backed by /admin). A SALES_REP is NOT staff: it has act-on-behalf-of
  /// writes and no staff surfaces at all, and showing it the Live projects tab
  /// would hand it a screen that answers 403.
  ///
  /// This is a RANK comparison, not `!= user`, precisely so that adding a role
  /// below modelArtist cannot silently widen the gate again.
  bool get isStaff => index >= UserRole.modelArtist.index;

  /// The /rep surface gate. Inclusive upward, mirroring the backend: a
  /// MODEL_ARTIST or ADMIN also passes it (see the note in models/User.ts).
  bool get isSalesRep => index >= UserRole.salesRep.index;

  bool get isAdmin => this == UserRole.admin;

  String get apiValue => switch (this) {
        UserRole.user => 'USER',
        UserRole.salesRep => 'SALES_REP',
        UserRole.modelArtist => 'MODEL_ARTIST',
        UserRole.admin => 'ADMIN',
      };

  /// Defensive parse — anything unrecognized is [user] (fail-closed).
  static UserRole fromApiValue(String? value) => switch (value) {
        'SALES_REP' => UserRole.salesRep,
        'MODEL_ARTIST' => UserRole.modelArtist,
        'ADMIN' => UserRole.admin,
        _ => UserRole.user,
      };
}
```

`fromApiValue` already failed closed to `user` and still does — that is the right default for a role
the client does not recognise, and it is what makes rolling the backend forward ahead of the client
safe.

> **Why `index` and not a switch?** Because the whole point of C5 is that the enum's order *is*
> the ladder. A rank getter that duplicates the order can drift from it; `index` cannot. The
> grep in this step is what makes relying on `index` safe, and the test below is what keeps it safe.

---

## Tests to write

### Backend — extend `recapture-api/tests/` (no new suite needed)

Add to whichever existing suite covers role gating (`tests/admin-projects.test.ts` has the
`requireRole` fixtures):

- **`SALES_REP` does not pass a `MODEL_ARTIST` gate.** Create a user with `role: 'SALES_REP'`, call
  any `/admin` route, assert `403` with code `FORBIDDEN`. This is the assertion that proves the
  rank renumbering went the right way round — if `SALES_REP` were accidentally ranked above
  `MODEL_ARTIST`, every other test in the file would still pass.
- **`ADMIN` still passes a `MODEL_ARTIST` gate.** Guards against an off-by-one in the renumber.

### Client — new `test/auth/user_role_test.dart`

Mirror the shape of `test/projects/projects_screen_role_gating_test.dart`.

- `UserRole.salesRep.isStaff` is **`false`** — the single most important assertion in this stage.
- `UserRole.modelArtist.isStaff` and `UserRole.admin.isStaff` are both `true`.
- `UserRole.salesRep.isSalesRep`, `.modelArtist.isSalesRep`, `.admin.isSalesRep` are all `true`;
  `UserRole.user.isSalesRep` is `false`.
- `fromApiValue('SALES_REP')` round-trips; `fromApiValue('WHATEVER')` and `fromApiValue(null)` are
  both `UserRole.user`.
- Every member's `apiValue` round-trips through `fromApiValue` — a loop over `UserRole.values`, so
  a future member added without a wire mapping fails here rather than in production.

---

## Done when

- [ ] `USER_ROLES` and `ROLE_RANK` carry four members in ladder order, with the inheritance
      consequence written into the file comment.
- [ ] `npx tsx scripts/set-user-role.ts` prints `SALES_REP` in its usage line, with the script
      unmodified.
- [ ] All four env vars are in `env.ts` **and** `.env.example`, in the same commit.
- [ ] The API boots with `PUBLIC_RESOLVER_BASE_URL` unset.
- [ ] `lib/domain/entities/user_role.dart` has `salesRep`, a rank-based `isStaff`, and `isSalesRep`.
- [ ] `cd recapture-api && npm run type-check && npm run lint && npm test` — green.
- [ ] `flutter analyze && flutter test` — green.
- [ ] A real `SALES_REP` account exists in dev: `npx tsx scripts/set-user-role.ts +91… SALES_REP`.
      Stages 4 and 6 need it.

---

## Rollback

Fully reversible with no data implications. `role` values already written as `SALES_REP` would
fail the Mongoose `enum` on the next save if the member were removed — so if you revert, first
`db.users.updateMany({role:'SALES_REP'}, {$set:{role:'USER'}})`. In practice nothing grants the
role until stage 4 ships, so a stage-1-only revert is clean.
