# This feature is holded for now. ❌❌❌
# Prompt — Admin User-Role Management

> Copy everything below the horizontal rule as the task prompt.
> Written against the repo as of `feature/recap-phase-2` @ `aceb9ce`.

---

## Context you must read first

Read **AGENTS.md** before writing any code. It is the single source of truth for
both codebases (Flutter client at the repo root, Node/TS backend in
`recapture-api/`): the API response envelope, config/secrets rules, the
data-layer and rate-limiting patterns, the PII/logging rules, the analytics
seam, and the testing conventions. **Where this prompt disagrees with AGENTS.md,
AGENTS.md wins** — tell me about the conflict rather than silently picking one.

## Goal

Give **ADMIN accounts only** a screen that lists users and changes each user's
role between `USER`, `MODEL_ARTIST` and `ADMIN`, persisted to the user document.

Today roles are granted exclusively by running `scripts/set-user-role.ts`
against the database. This feature adds the first in-product grant path.

## Three constraints that shape the whole design — do not "solve" them by ignoring them

1. **The codebase currently states there is deliberately no grant endpoint.**
   `recapture-api/src/models/User.ts:8-11` says roles are *"Granted only via
   scripts/set-user-role.ts (DB flag) — there is deliberately no grant UI or
   endpoint."* `lib/domain/entities/user_role.dart:5-7` repeats it: *"roles are
   granted server-side only (DB flag) — the client never mutates them."*

   This prompt **reverses that decision on purpose**. Part 0 is to update both
   comments to describe the new reality (ADMIN-only endpoint + the script). A
   comment that contradicts the code is a bug in this repo.

2. **The backend refuses to ship raw phone/email.** `accountSnapshot` in
   `recapture-api/src/routes/auth.ts:71-88` returns `contactMasked` +
   `contactChannel`, never the raw identifier, and
   `tests/auth-me-profile.test.ts` asserts no raw value appears in the body.

   **This prompt keeps that stance.** The admin list ships `displayName`,
   `contactMasked`, `contactChannel` — the same three fields the Profile screen
   already renders — plus a short id suffix so two similar masks are still
   distinguishable. Do **not** add raw contact to this payload. If you believe
   the screen cannot work without it, stop and say so; that is a policy change to
   record in AGENTS.md, not one to make quietly.

3. **Role comparison is inclusive upward, never `===`.** `hasRoleAtLeast` in
   `recapture-api/src/models/User.ts:19-21` is the ONE comparison for gating.
   The new endpoints gate on `requireRole('ADMIN')`. The *assignment* itself is
   an exact value — `USER_ROLES` membership, validated by Zod.

---

## Part 0 — Correct the stale "no grant endpoint" comments

- `recapture-api/src/models/User.ts:8-11` — say roles are granted via
  `PATCH /admin/users/:id/role` (ADMIN-only) **or** `scripts/set-user-role.ts`.
- `lib/domain/entities/user_role.dart:5-7` — same correction on the client side.
- Neither change alters behaviour; do them in the same commit as Part 1 so the
  comments are never ahead of or behind the code.

---

## Part 1 — Backend (`recapture-api/`)

Everything lands in the existing staff router, `src/routes/admin.ts`, which
already runs `requireAuth` then `requireRole('MODEL_ARTIST')` at lines 58-59.
Both new routes add their **own** `requireRole('ADMIN')` on top, exactly the way
the destructive routes at lines 241-243 and 326-328 already do. Do not loosen
the router-level gate and do not create a new router.

### 1.1 `GET /admin/users` — paginated, searchable user list

- `requireRole('ADMIN')` on the route.
- Query: `limit` (1-100, default 20), `cursor` (opaque), `q` (optional search).
- Sort + keyset: `createdAt DESC, _id DESC`. **Reuse `encodeCursor`/`decodeCursor`
  from `src/utils/cursor.ts`** — it is already a `(Date, id)` keyset; pass
  `createdAt` where the project list passes `updatedAt`. A malformed cursor is a
  400 with `INVALID_REQUEST`, matching `admin.ts:79-92`.
- `q` matches case-insensitively against `displayName`, `email` and `phone`.
  **Escape regex metacharacters** before building the query — an admin typing
  `.*` must not turn into a match-all, and `$regex` over unescaped input is an
  injection surface. Trim, cap at 100 chars, ignore when empty.
- Each item is the SAME masked shape the Profile screen already parses, plus one
  field:

  ```ts
  {
    id: string,                      // Mongo _id
    role: UserRole,                  // 'USER' | 'MODEL_ARTIST' | 'ADMIN'
    displayName: string | null,
    contactMasked: string | null,    // utils/maskIdentifier.ts
    contactChannel: 'sms' | 'email', // contactChannelFor()
    createdAt: string,               // ISO
    avatarUrl: string | null,        // presigned, same as accountSnapshot
  }
  ```

  Build it by **factoring the existing `accountSnapshot`** (`auth.ts:71`) into a
  shared helper both routes call — do not write a second, drifting projection.
  Put it where both can import it (e.g. `src/services/accountSnapshotService.ts`)
  and have `auth.ts` use the shared version.
- Response: `{ status: 'success', items, nextCursor }` — the envelope
  `admin.ts:109` already uses.
- **`avatarUrl` is a presigned bearer credential.** It may appear in the response
  body and nowhere else: never a log line, never analytics. Same rule as
  `auth.ts:62-64`.

### 1.2 `PATCH /admin/users/:id/role` — set one user's role

- `requireRole('ADMIN')`.
- Params: `:id` must match the 24-hex ObjectId regex already used by
  `adminProjectIdParamsSchema` (`src/validation/adminSchemas.ts:24-31`).
- Body: `{ role: 'USER' | 'MODEL_ARTIST' | 'ADMIN' }`, Zod `.strict()`, built from
  `z.enum(USER_ROLES)` so the enum has exactly one definition.
- Returns the **same item shape as 1.1** for the updated user, so the client has
  one parser, not two.

**Three refusals, all server-side — the UI hiding a button is not a guard:**

| Case | Status | `code` |
|---|---|---|
| Target user does not exist | 404 | `NOT_FOUND` |
| Actor is changing their **own** role | 409 | `SELF_ROLE_CHANGE` |
| The change would leave **zero** ADMINs | 409 | `LAST_ADMIN` |

- *Self-change*: compare `req.user!.userId` to `:id`. An admin demoting
  themselves mid-session locks themselves out with no way back except the DB
  script. Refuse it.
- *Last admin*: when demoting an ADMIN, `countDocuments({ role: 'ADMIN' })` must
  be > 1. The count and the update must not interleave — use a conditional update
  or a re-check inside a transaction. A race here bricks the deployment, so state
  in a comment which approach you chose and why it is safe.
- A no-op change (role already equals the requested value) **succeeds** and
  returns the snapshot — it is idempotent, not an error.

### 1.3 Analytics

Add to `src/validation/analyticsSchemas.ts` beside the existing `ADMIN_*` block
(lines 66-71) and register the props schemas in `EVENT_SCHEMAS` (around line 820):

- `ADMIN_USERS_LISTED` → `{ actor_role, page_size, has_query: boolean }`
- `ADMIN_USER_ROLE_CHANGED` → `{ actor_id_hash, target_id_hash, from_role, to_role }`

Hash both ids with `hashIdentifier` from `src/utils/otp.ts`, the way
`requireRole.ts:48` and `admin.ts:102` already do. **Never** put `contactMasked`,
`displayName`, `avatarUrl` or a raw identifier in an analytics prop.

### 1.4 Backend tests — `tests/admin-user-roles.test.ts`

Vitest + Supertest + mongodb-memory-server, following `tests/admin-projects.test.ts`.
**Remember the env-before-import gotcha** documented in the existing auth tests.

- `GET /admin/users` as ADMIN → 200, items sorted `createdAt DESC`
- `GET /admin/users` as MODEL_ARTIST → **403** (the router-level gate passes it;
  the route-level ADMIN gate must not)
- `GET /admin/users` as USER → 403; with no token → 401
- **The list body contains no raw phone or email substring** — assert explicitly
  against seeded values. This test *is* the PII guardrail; it is the most
  important one in the file.
- `?q=` matches a display name, matches an email fragment, and a `q` full of
  regex metacharacters returns 200 with no crash and no accidental match-all
- cursor pagination: two pages, no overlap, no gap
- `PATCH …/role` promotes USER → MODEL_ARTIST → ADMIN and persists
- `PATCH …/role` on self → 409 `SELF_ROLE_CHANGE`
- `PATCH …/role` demoting the only ADMIN → 409 `LAST_ADMIN`; demoting one of two
  ADMINs → 200
- `PATCH …/role` with `{ role: 'SUPERUSER' }` → 400; unknown `:id` → 404
- `PATCH …/role` as MODEL_ARTIST → 403
- **The role change takes effect on the very next request** — `requireRole` reads
  the role fresh from the DB on every call (`requireRole.ts:5-8`), so a demoted
  admin's next `/admin/users` call is a 403 with the SAME token. Assert this; it
  is the property the whole feature leans on.

---

## Part 2 — Client (Flutter)

### 2.1 Domain

**New** `lib/domain/entities/managed_user.dart` — immutable, one user row:

```dart
ManagedUser {
  String id;
  UserRole role;
  String? displayName;
  String? contactMasked;
  String contactChannel;   // 'sms' | 'email'
  DateTime createdAt;
  String? avatarUrl;
}
```

Parse `role` with the existing `UserRole.fromApiValue` — its fail-closed default
(`user_role.dart:32-37`) applies here too. Add a `copyWith` for the optimistic
update in 2.3.

`UserRole` also needs a **display label** (`User`, `Model artist`, `Admin`). Put
it on the enum next to `apiValue` so wire value and label live together and can
never drift.

### 2.2 Data — `lib/data/repositories/admin_users_repository.dart`

Model it on `lib/data/repositories/live_projects_repository.dart`, which is the
repo's pattern for a staff surface: an abstract interface, a `Remote…` impl on
the app Dio (`api_client.dart`, which carries the Bearer/refresh interceptor),
and a **mapped failure enum** — the UI renders copy per category and never a raw
code, message or URL.

```dart
Future<({List<ManagedUser> items, String? nextCursor})> fetchUsers({
  String? cursor, String? query, int limit = 20,
});
Future<ManagedUser> setRole(String userId, UserRole role);
```

`AdminUsersFailure` needs, at minimum:

| Enum value | Trigger |
|---|---|
| `forbidden` | 403 — the account is not (or is no longer) ADMIN |
| `notFound` | 404 — target user is gone |
| `selfChange` | 409 `SELF_ROLE_CHANGE` |
| `lastAdmin` | 409 `LAST_ADMIN` |
| `network` | transport (offline, timeout) |
| `server` | anything else |

Map on the `code` in the envelope, not on message text.

**PII:** `contactMasked` and `displayName` must never be logged or passed to
analytics from the client either — the same rule `account_repository.dart:16-18`
states for the Profile screen.

### 2.3 Application — `lib/application/admin/admin_users_notifier.dart`

Riverpod, matching the surrounding notifiers:

- Holds `AsyncValue<List<ManagedUser>>` + `nextCursor` + `isLoadingMore`.
- A debounced (~300 ms) search query resets the list and re-fetches from page 1.
  A stale in-flight response for an older query must be **discarded**, not
  merged — the usual last-write-wins guard.
- `setRole(userId, role)` is **optimistic**: swap the row's role immediately,
  call the API, replace the row with the server's returned snapshot on success,
  and **roll back to the previous role** on failure while surfacing the mapped
  `AdminUsersFailure`. Track per-row in-flight state so one pending change does
  not disable the whole list.
- If a call answers 403, invalidate `userRoleProvider` — the actor's own role may
  have moved underneath them.

### 2.4 Route + gate

- `AppRoutes.adminUsers = '/admin/users'`, `AppRouteNames.adminUsers = 'adminUsers'`
  in `lib/app/routes/app_router.dart` (the const blocks at lines 69-157 and 159+),
  beside the other `/admin/*` staff routes.
- Wrap the builder in `FlowBackScope`, like `modelHistory` at line 423.
- Map `AppRoutes.adminUsers => AppRoutes.projects` in
  `lib/app/routes/flow_back.dart`'s switch (beside `AppRoutes.profile` at line 51)
  so back returns to Projects.
- **Route-level gate:** a non-admin who deep-links `/admin/users` gets redirected
  to `AppRoutes.projects`. Use the route's own `redirect` — the pattern at
  `app_router.dart:597` — reading `isAdminProvider`
  (`lib/application/auth/user_role_notifier.dart:122`). This is a UX guard on top
  of the server's 403, never a replacement for it.

### 2.5 The Projects app-bar entry point

`lib/presentation/screens/projects/projects_screen.dart:573` currently reads:

```dart
actions: const [CatalogEntryAction(), _ProfileAvatarAction()],
```

Insert a new admin-only action **first**, giving the requested order
**role-management → catalog → profile**:

```dart
actions: const [
  AdminUsersEntryAction(),   // renders nothing unless isAdminProvider
  CatalogEntryAction(),
  _ProfileAvatarAction(),
],
```

- `AdminUsersEntryAction` is a `ConsumerWidget` that returns `SizedBox.shrink()`
  when `isAdminProvider` is false — non-admins see the app bar exactly as it is
  today, with no gap and no layout shift.
- Copy the shape of `CatalogEntryAction`
  (`lib/presentation/screens/catalog/catalog_screen.dart:657-668`): `IconButton`,
  `tooltip: 'User roles'`, `AppColors.textSecondary`, and
  `context.goNamed(AppRouteNames.adminUsers)` — `go()`, not `push()`, because this
  is a top-level destination and `FlowBackScope` owns the back edge.
- Icon: `Icons.manage_accounts_outlined` — visually distinct from
  `storefront_outlined` (catalog) and `account_circle_outlined` (profile), which
  matters in a row of three.
- The actions line carries a comment explaining the current two-item order.
  Extend it to explain the three-item order rather than leaving a comment that
  describes two items.

### 2.6 The screen — `lib/presentation/screens/admin/admin_users_screen.dart`

App bar title **"User roles"**, back arrow to Projects, `AppColors.bgPrimary` —
match `profile_screen.dart:89-104`.

A search field (`AppTextField`) pinned under the app bar, then the list. Each user
is one card (`AppCard`, `AppSpacing` tokens throughout — no magic numbers) split
**left / right**:

```
┌────────────────────────────────────────────────────────┐
│  ╭───╮                                                 │
│  │ 👤│  Ashish Kuldeep              ┌────────────────┐ │
│  ╰───╯  +91 ••••• ••210  ·  #a3f9   │  User      ▾   │ │
│                                     └────────────────┘ │
└────────────────────────────────────────────────────────┘
   └──────── left ────────┘            └──── right ────┘
```

**Left** — avatar, then identity:
- Avatar: the user's picture when `avatarUrl` is present, else
  `Icons.account_circle_outlined`. Reuse the circle-with-royalGold-ring treatment
  from `_ProfileAvatarAction._picture` (`projects_screen.dart:722-745`), including
  its `errorBuilder` fallback — an undecodable image must degrade to the glyph,
  never to a broken-image icon.
- Line 1: `displayName`, or `'Unnamed user'` in `AppColors.textMuted` when null.
- Line 2: `contactMasked` (channel icon: `Icons.sms_outlined` /
  `Icons.mail_outline`), then a `·` and the **last 4 characters of `id`** — the
  disambiguator for two users with similar masks. Both muted, one line, ellipsized.

**Right** — the role control:
- A `DropdownButtonFormField<UserRole>` (or a `PopupMenuButton` styled as a pill —
  pick one and use it for every row) listing all three roles by display label,
  current value selected.
- Selecting a value fires `setRole` immediately. **No confirm dialog for a
  promotion to `MODEL_ARTIST` or a demotion; a confirm dialog for granting
  `ADMIN`**, because that hands over the ability to change everyone else's role.
  Use `delete_confirmation_modal.dart`'s structure for consistency, with copy
  naming the user and the new role.
- While a row's change is in flight: disable that row's control and show a small
  inline `AppLoadingIndicator`; the rest of the list stays interactive.
- On failure the control snaps back to the previous role **and** a snackbar
  carries the mapped copy:
  - `selfChange` → "You can't change your own role."
  - `lastAdmin` → "There must always be at least one admin."
  - `forbidden` → "Your admin access has been removed."
  - `notFound` → "That user no longer exists."
  - `network` → "You're offline. Try again."
  - `server` → "Something went wrong. Try again."
- Disable the current user's own row control outright (the server refuses it
  anyway) with a "You" chip on the row, so the refusal is never a surprise.

States, all four, no exceptions:
- **Loading (first page)** — skeleton cards in the list's shape, mirroring
  `_SkeletonList` (`projects_screen.dart:750+`).
- **Error** — the `_ErrorView` retry pattern (`projects_screen.dart:817-830`).
- **Empty** — for a search with no matches, copy that names the query; for a
  genuinely empty list, the neutral empty state.
- **Loaded** — plus infinite scroll: fetch the next page when the list nears the
  bottom, with a trailing spinner while `nextCursor != null`.

Pull-to-refresh via the shared `RefreshIndicator` treatment
(`projects_screen.dart:667-674`).

### 2.7 Client tests

`test/` — follow the existing widget/unit test layout:

- `admin_users_notifier` unit tests: optimistic swap applied; **rollback on
  failure restores the exact previous role**; a stale search response is
  discarded; pagination appends without duplicating.
- Widget test: with `isAdminProvider` overridden **false**, the Projects app bar
  has exactly two actions; overridden **true**, exactly three, in the order
  role-management, catalog, profile.
- Widget test: the screen renders `contactMasked` and **never** a raw identifier
  (the client-side half of the PII guardrail).
- Widget test: the current user's own row control is disabled.

---

## Out of scope — do not build these

- Any change to `scripts/set-user-role.ts` (it stays; it is the recovery path
  when there is no admin left).
- Bulk role changes, a role-history/audit-log UI, or user deletion/suspension.
- Raw phone/email anywhere in a response, a log, or an analytics prop.
- Making `role` a JWT claim. It is deliberately a fresh DB read per request
  (`requireRole.ts:5-8`) and this feature depends on that.

---

## Definition of done

Backend (`recapture-api/`):
- `npm run lint`
- `npm run type-check`
- `npm run test`

Client (repo root):
- `flutter analyze`
- `flutter test`

Then report using the AGENTS.md handoff format: what changed, how it was verified
(commands with pass/fail), risks and follow-ups, and scope confirmation that no
unrelated refactor was included.

Call out explicitly in the handoff:
1. Which concurrency approach you chose for the last-admin guard, and why it is
   race-safe.
2. That the `User.ts` and `user_role.dart` "no grant endpoint" comments were
   updated — this is a documented policy reversal, and reviewers must see it named.
