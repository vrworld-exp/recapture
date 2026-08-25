# Android Permission Detection — Manual Verification Matrix

**Purpose.** The widget test `test/precapture/android_dont_ask_again_test.dart`
mocks the facade statuses and proves the **gate UI maps them to the right CTA**
("Allow" vs "Settings"). This document closes the other half: that the **native
layer actually PRODUCES** `denied` vs `permanentlyDenied` vs the never-asked case
correctly. That detection depends on real Android framework behaviour
(`ActivityCompat.shouldShowRequestPermissionRationale` + the persisted
requested-before flag) which a pure Flutter widget test cannot exercise.

Code under verification:
- `android/app/src/main/kotlin/com/mayasabhaxr/recapture/permissions/PermissionManager.kt`
  — `check()` → `aggregateUnprompted()`, `request()` → `aggregateAfterResult()`,
  and the `requested_<permission>` flag (`markRequested` / `wasRequested`).
- Status strings returned to Dart: `granted | denied | permanentlyDenied | restricted`,
  normalized by `normalizeNativeStatus()` in `lib/platform/permissions_service.dart`.

The crux (why this matters): on Android **both** never-asked and "Don't ask
again" report `shouldShowRequestPermissionRationale == false`. They are
distinguished ONLY by the persisted requested-before flag:
`wasRequested == false` ⇒ `denied` (never-asked, re-promptable);
`wasRequested == true && !shouldShowRationale` ⇒ `permanentlyDenied`.

## How to run (emulator or device, no automation required)

Use a debug build with a fresh install (so the `mayasabhaxr.permissions`
SharedPreferences flags start empty). Camera is the simplest permission to drive.
After each case, read the status the channel returns (log it from
`PermissionsService.status`/`request`, or observe the gate CTA: Allow ⇔
`denied`/`notRequested`, Settings ⇔ `permanentlyDenied`/`restricted`).

| # | Precondition | Action | Expected channel status | Expected gate CTA |
|---|---|---|---|---|
| 1 | Fresh install, never requested | `check(camera)` on gate load | `denied` (re-promptable; `wasRequested=false`) | **Allow** |
| 2 | Fresh install | Tap **Allow** → OS dialog → **Allow** | `granted` | Granted (no CTA) |
| 3 | Fresh install | Tap **Allow** → OS dialog → **Deny** (1st deny, no "don't ask again") | `denied` | **Allow** (re-promptable) |
| 4 | After #3 | Tap **Allow** → OS dialog → check **Don't ask again** + **Deny** | `permanentlyDenied` | **Settings** |
| 5 | After #4 | Background → enable Camera in OS Settings → return (resume re-check) | `granted` | Granted (no CTA) |
| 6 | After #4 | Background → leave disabled → return | `permanentlyDenied` | **Settings** (no in-app re-prompt) |
| 7 | Policy-restricted device (MDM), if available | `check(camera)` | `restricted` | **Settings** |

Pass criteria:
- #1 and #3 BOTH yield `denied`/Allow, and #4 yields `permanentlyDenied`/Settings
  — i.e. the never-asked vs "Don't ask again" split is detected correctly.
- #4 never offers an in-app re-prompt; the only recovery is Settings (#5/#6).
- The requested-before flag persists across #3→#4 (deny once stays re-promptable;
  deny-with-don't-ask-again flips to permanentlyDenied).

## Notes / scope

- Per-API-level concrete-permission mapping (e.g. granular media 33+,
  `ACTIVITY_RECOGNITION` 29+) is unit-tested in
  `android/app/src/test/.../PermissionMapperTest.kt`; this matrix covers the
  *runtime detection* the mapper test cannot.
- An automated equivalent would be an `androidTest` instrumentation case driving
  `requestPermissions` + UI Automator on the system dialog; not wired into CI
  here, hence this manual matrix. If/when instrumentation lands, it should assert
  rows #1, #3, #4 (the never-asked / deny-once / don't-ask-again trio).
- The launcher (`openAppSettings`) returns on launch and never reports the user's
  choice — the post-Settings status is always observed by the gate's resume
  re-check (rows #5/#6), matching the widget test's resume assertion.
