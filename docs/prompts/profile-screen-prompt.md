# Prompt — Profile / Account Screen

> Copy everything below the horizontal rule as the task prompt.
> Written against the repo as of `feature/manual-cap-3` @ `d6b87b5`.

---

## Context you must read first

Read **AGENTS.md** before writing any code. It is the single source of truth for
both codebases (Flutter client at the repo root, Node/TS backend in
`recapture-api/`): the API response envelope, config/secrets rules, the
data-layer and rate-limiting patterns, the PII/logging rules, the analytics
seam, and the testing conventions. **Where this prompt disagrees with AGENTS.md,
AGENTS.md wins** — tell me about the conflict rather than silently picking one.

## Goal

The profile icon in the Projects app bar is currently a dead no-op
(`onPressed: () {}` at `lib/presentation/screens/projects/projects_screen.dart:544`).
Wire it to a new **Profile screen** that shows the signed-in user's avatar,
display name, masked contact identifier, and a **Sign out** action.

## Two constraints that shape the whole design — do not "solve" them by ignoring them

1. **No user name exists anywhere today.** `IUser` in
   `recapture-api/src/models/User.ts:23-33` has `email`, `phone`, `role`,
   `emailVerified`, `phoneVerified`, `createdAt` — no `name`. The client has
   none either. A name therefore requires a new backend field (Part 1).

2. **The backend deliberately refuses to ship phone/email.**
   `recapture-api/src/routes/auth.ts:26-27` states it explicitly: *"Deliberately
   returns NO raw phone/email (PII stance: the client doesn't need them, so they
   don't ship)"* — and `lib/data/repositories/account_repository.dart:9-10`
   repeats the same contract. `OtpRequest` (which does hold the identifier) is
   process-memory-only and cleared on successful login, so it is gone after a
   cold start and cannot be the source.

   **This prompt keeps that stance intact** by returning a *masked* identifier,
   never the raw one. If you believe the screen genuinely needs the raw value,
   stop and say so — that is a policy decision to record in AGENTS.md, not a
   change to make quietly.

---

## Part 1 — Backend (`recapture-api/`)

### 1.1 `User` model — `src/models/User.ts`

Add exactly one optional field. Nothing else changes.

```ts
displayName?: string;   // Schema: { type: String, trim: true, maxlength: 60 }
```

No migration is needed — an absent field materializes as `undefined`, the same
reasoning already documented for the `role` default at line 59.

### 1.2 `GET /auth/me` — `src/routes/auth.ts:29-56`

Extend the response's `user` object with three fields. **Do not add raw `phone`
or `email`.** Update the route's doc-comment so it says *masked-only* instead of
*none* — the comment must keep describing what the code actually does.

```ts
displayName:    user.displayName ?? null,
contactMasked:  maskIdentifier(user),   // "+91 ••••• ••210" | "a•••@gmail.com" | null
contactChannel: user.phone ? 'sms' : 'email',
```

Write `maskIdentifier` as a small pure helper in a new
`src/utils/maskIdentifier.ts`:

- **phone** → dial prefix + last 3 digits (`+91 ••••• ••210`)
- **email** → first character + domain (`a•••@gmail.com`)
- **missing / unparseable identifier** → `null`, never a throw

Mirror `OtpRequest.maskedDestination` in
`lib/application/auth/otp_request.dart:41-51` **exactly**, so the OTP screen and
the Profile screen never disagree about how the same identifier looks.

### 1.3 `PATCH /auth/me` — new route, same router

- `requireAuth`, body `{ displayName: string }`
- Validate with Zod in `src/validation/authSchemas.ts`: trimmed, 1–60 chars,
  rejects control characters
- Returns the **same `user` snapshot shape** as `GET /auth/me` so the client has
  one parser, not two
- Validation failure → the standard error envelope with a stable rule id
  (follow the manifest-validation convention)

### 1.4 Backend tests — `src/__tests__/auth-me-profile.test.ts`

Vitest + Supertest + mongodb-memory-server. **Remember the env-before-import
gotcha** documented in the existing auth tests.

- `GET /auth/me` returns `displayName`, `contactMasked`, `contactChannel`
- **The response body contains no raw phone or email substring** — assert this
  explicitly against the seeded values. This test *is* the PII guardrail; it is
  the most important one in the file.
- `PATCH /auth/me` persists a name
- `PATCH /auth/me` rejects: empty string, 61 chars, embedded control characters
- `PATCH /auth/me` without a token → 401

---

## Part 2 — Client (Flutter)

### 2.1 Domain + data

**New** `lib/domain/entities/user_profile.dart` — immutable:

```dart
UserProfile {
  String id;
  UserRole role;
  String? displayName;
  String? contactMasked;
  String contactChannel;   // 'sms' | 'email'
  DateTime createdAt;
}
```

Give it a **defensive `fromJson`** that tolerates every new field being absent —
an old backend must never crash a new client (same defensive posture as
`AuthSession.fromJson`).

**Extend** `lib/data/repositories/account_repository.dart`:

```dart
Future<UserProfile> fetchProfile();
Future<UserProfile> updateDisplayName(String name);
```

**Leave `fetchRole()` exactly as it is.** `UserRoleNotifier` depends on its
fail-closed throw-on-failure contract; changing it silently changes staff gating.

### 2.2 State — new `lib/application/auth/profile_provider.dart`

An `AsyncNotifierProvider<UserProfile>` that:

- fetches on first watch
- exposes `refresh()`
- **resets when `authProvider` transitions to `AuthUnauthenticated`** — use the
  same `ref.listen` + epoch-guard pattern as `UserRoleNotifier`
  (`lib/application/auth/user_role_notifier.dart:41-55`) so a second user can
  never see the first user's name
- does **not** persist to Hive

### 2.3 Route — `lib/app/routes/app_router.dart`

- `AppRoutes.profile = '/profile'` and `AppRouteNames.profile = 'profile'`
- Registered as a protected route (the existing guard covers it automatically —
  do not re-check auth inside the screen; the guard contract at line 136 says
  screens must not)
- Wrapped in `FlowBackScope`
- Reached by **push**, not `go`, so hardware back returns to Projects

### 2.4 Screen — `lib/presentation/screens/profile/profile_screen.dart`

**Theme rules are non-negotiable** (see `lib/app/theme/app_colors.dart:5-11`):

- Never a hex literal outside `app_colors.dart` — always `AppColors.*`
- `bgPrimary` covers 70–80% of the screen
- `mirageRed` on the single primary action only
- `royalGold` at max 2–3% — spend it on the **one** avatar ring, nowhere else
- All spacing from `AppSpacing`, all type from `Theme.of(context).textTheme`

**Layout, top to bottom:**

| Element | Spec |
|---|---|
| `AppBar` | transparent, `elevation: 0`, title "Profile", back arrow routed through `FlowBackScope`'s `navigateBack` |
| **Avatar** | centered, `AppSpacing.xxxl` below the bar. 96px circle on `surface1` with a 1.5px `royalGold` border ring. Contains initials derived from `displayName`; falls back to `Icons.person_outline` in `textSecondary` when there is no name. **This is the "mock logo" — pure Dart, no asset, no network image.** |
| **Display name** | `titleLarge` / `textPrimary`. Null → "Add your name" in `textMuted`. Tapping the name (or a trailing pencil in `textSecondary`) opens a small edit dialog calling `updateDisplayName`, optimistic with rollback on failure (projects-state convention). |
| **Masked contact** | `bodyMedium` / `textSecondary`, prefixed by `Icons.phone_outlined` or `Icons.mail_outline` chosen by `contactChannel`. Null → **hide the row entirely**, do not show a placeholder. |
| **Info card** | `AppCard` on `surface1`: "Member since {formatted createdAt}". **Only when `isStaffProvider` is true**, a role row using `AppStatusPill`. A non-staff user must see no role text at all. |
| *(spacer)* | pushes the action to the bottom |
| **Sign out** | full-width `AppButton`, `variant: secondary`, `Icons.logout`, label in `AppColors.error`. **Not `mirageRed`** — red-on-red fights the CTA rule, and sign-out is destructive rather than primary. |
| **Version** | app version line at the very bottom, `bodySmall` / `textMuted` |

**States:**

- `AsyncLoading` → skeleton bars on `surface2` for the avatar/name/contact block.
  Match the existing `_SkeletonList` style in `projects_screen.dart`.
- `AsyncError` → inline retry calling `refresh()`.
- **In both states the Sign out button stays fully enabled.** A user whose
  profile will not load is exactly the user who most needs to sign out — never
  gate it behind a successful fetch.

### 2.5 Sign-out behavior — read carefully, this is the part that breaks

1. Tap → platform-adaptive destructive confirm. **Reuse the existing pattern**
   in `lib/presentation/widgets/delete_confirmation_modal.dart`: Material
   `AlertDialog` on Android, `CupertinoActionSheet` on iOS, branching on
   `Theme.of(context).platform` (**not** `Platform.isIOS`, so tests can force
   either side). Add a `ConfirmKind.signOut` variant in
   `lib/domain/entities/confirm_kind.dart` with its own copy — *"You'll need to
   sign in again."* Any dismissal resolves `false`.

2. On confirm → `await ref.read(authProvider.notifier).logout()`.

3. **Do not navigate manually.** `logout()` already clears secure storage plus
   the `active_session`, `projects_cache`, and `offline_queue` boxes
   (`lib/application/auth/auth_notifier.dart:201-221`), and the router's
   `refreshListenable` guard bounces every protected route to `/auth`
   (`app_router.dart:156-163`). A manual `context.go` here **races that
   redirect** and can strand the user on a half-torn-down screen.

4. Show a blocking progress state on the button while `logout()` is in flight.
   The best-effort server-side revoke can take a moment against a cold Render
   backend, and a double-tap must not fire two logouts.

### 2.6 Wire the icon

Replace the empty `onPressed: () {}` at
`lib/presentation/screens/projects/projects_screen.dart:544` with
`context.pushNamed(AppRouteNames.profile)`. Keep the
`Icons.account_circle_outlined` glyph and its `textSecondary` color exactly as
they are.

### 2.7 Analytics

Add `profile_screen_opened` and `profile_sign_out` through the existing
`Analytics.logEvent` seam. Carry **only** the event name and `device_type` — no
identifier, no display name, no masked contact. The analytics layer's PII
guardrail will reject anything else, and it should.

---

## Part 3 — Client tests (`test/auth/profile_screen_test.dart`)

- Renders name, masked contact, and the initials avatar from a fake `UserProfile`
- No-name state shows "Add your name" and the fallback glyph
- Sign out shows the confirm; **dismissing calls `logout()` zero times**;
  confirming calls it **exactly once**
- Sign out stays tappable while the profile provider is in `AsyncError`
- Role pill absent for a non-staff user, present for staff
- Double-tapping Sign out fires `logout()` once

---

## Out of scope — do not build, do not leave TODOs promising them

Avatar image upload, changing the phone/email, account deletion, notification
settings, theme settings, any second tab.

## Definition of done

- `flutter analyze` clean; `flutter test` green
- `npm test` green in `recapture-api/`
- The no-raw-PII assertion in `auth-me-profile.test.ts` passes
- Tapping the Projects app-bar avatar opens Profile; Sign out returns the user
  to the auth screen with every local box cleared
- **Not device-tested** unless you say otherwise — state plainly in your summary
  what you verified and what you did not.
