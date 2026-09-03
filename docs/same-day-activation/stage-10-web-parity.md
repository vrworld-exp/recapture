# Stage 10 — Web Parity for the Rep Surface

**Side:** client (Flutter web) + a little backend · **Size:** M (≈ 1 day) · **Depends on:** stage 6

---

## Goal

At the end of this stage the rep surface behaves identically on the app and in a browser, **except
where the browser physically cannot** — and every one of those exceptions is a deliberate, tested,
documented gate rather than a broken button.

This is not a "web version". It is the same code shipping to both targets, which is how every other
surface in this repo already works. The phase's standing rule applies unchanged:

> Every prompt ships Android/iOS **and** Flutter web in the same change.

---

## Prerequisites

- Stage 6 ticked.
- **Read [`../next-phase/web-capability-matrix.md`](../next-phase/web-capability-matrix.md) first.**
  It is the artifact F11 produced, it is enforced by `test/catalog/web_parity_test.dart`, and this
  stage extends it rather than starting a second one.

---

## The three rules this stage is bound by

These are established repo conventions, not suggestions. Breaking them fails an existing test.

### 1. `kIsWeb` is for capabilities, never for layout

Layout comes from `BoxConstraints` — a narrow browser window is a phone layout, not a squeezed
desktop one. Grepping the catalog surface for `kIsWeb` returns **only comments explaining why it is
not used there**. `test/catalog/web_parity_test.dart` enforces this structurally over the catalog
tree; this stage adds the rep tree to that guard.

### 2. Platform splits are conditional imports, not runtime branches

```dart
import 'rep_scan_stub.dart'
    if (dart.library.io) 'rep_scan_io.dart'
    if (dart.library.js_interop) 'rep_scan_web.dart';
```

Two properties, both load-bearing:

- **The unsupported path is not compiled in.** `dart:io` cannot reach a web build even by accident.
- **The screen asks rather than tests.** A `kIsWeb` branch is untestable by construction — the
  untaken half is not compiled into the test binary — so the other platform's rendering is
  unverifiable from the only run CI does.

### 3. An unavailable capability is **hidden**, never disabled

A greyed-out Scan button on web is a worse answer than no Scan button. The existing rows follow
this both ways round: Share is hidden on web, Open-in-new-tab is hidden on mobile. The matrix is
**genuinely mixed**, which is exactly why the flags are named for capabilities (`canShare`,
`canOpen`) and not `isWeb`.

---

## New capability rows

Append these to `../next-phase/web-capability-matrix.md`, continuing its numbering. Do not start a
second table.

| # | Capability | Android / iOS | Web | Mechanism | Seam |
|---|---|---|---|---|---|
| 15 | **Rep sign-in, activation, delegated catalog list** | ✅ | ✅ | Plain HTTP through `dioProvider`. No device capability at all | `rep_repository.dart` |
| 16 | **Manual code entry / paste** | ✅ | ✅ | Same normaliser, same validator, both targets | `rep_activation_screen.dart` |
| 17 | **Camera QR scan** | ✅ | ⛔ **button hidden** | `kCanScanQrCode` — see note G | `rep_scan_{io,web,stub}.dart` |
| 18 | **Dish capture (fresh scan)** | ✅ | ⛔ **source hidden** | Same answer as note A — see note H | `rep_add_dish_screen.dart` |
| 19 | **Dish from a finished capture** | ✅ | ✅ | Picks an existing model by id; opens no camera | existing `add_product_screen.dart` |
| 20 | **Dish image-only** | ✅ | ✅ | Bytes end-to-end, existing picker | existing `product_image_picker.dart` |
| 21 | **Pending → ready polling** | ✅ | ✅ | `Timer`/`Future.delayed`; identical on both | `catalog_products_notifier.dart` |
| 22 | **Standee QR download (PNG/PDF)** | ✅ share sheet | ✅ `<a download>` blob | **Reuse row 9's seam unchanged** | `catalog_qr_service.dart` |
| 23 | **Admin QR batch CSV export** | ✅ | ✅ `<a download>` blob | Row 9's seam, generalised — see note I | `qr_batch_export_service.dart` |
| 24 | **Deep link into `/rep/activate?code=`** | ⚠️ custom scheme only | ⚠️ needs the note F rewrite | See note J | `app_router.dart` |

---

## Steps

### 1. Extend the structural guard to the rep tree

**File:** `test/catalog/web_parity_test.dart` (or a sibling `test/rep/web_parity_test.dart` that
shares its helpers)

The structural half of that suite reads source files and asserts: no `dart:io` on a path the web
build compiles, no `kIsWeb` deciding layout, every conditional-import seam complete in all three
variants. **Add `lib/presentation/screens/rep/`, `lib/application/rep/` and
`lib/data/repositories/rep_repository.dart` to the tree it walks.**

Do this **first**, before writing the screens. The guard then tells you the moment a rep file
reaches for `dart:io`, instead of `flutter build web` telling you months later.

Mutation-check it the way the existing suite was: introduce a `dart:io` import and a `kIsWeb`
reference into a rep file and confirm both fail.

### 2. The scan capability seam — note G

Three files, matching `catalog_link_delivery_{io,web,stub}.dart` exactly:

```dart
// lib/application/rep/rep_scan_web.dart
//
// Camera QR scanning does not exist in this build.
//
// It is not a browser limitation in principle — getUserMedia plus a decoder
// would work — but the decoder is a new package, which the phase forbids
// without justification, and the rep's own OS camera already scans the standee
// and opens the link (note J). So the button is HIDDEN here and manual entry,
// which is present on BOTH targets, is what the screen offers instead.
const bool kCanScanQrCode = false;

Future<String?> scanQrCode() =>
    throw UnsupportedError('No camera scanner in the browser build.');
```

The `io` variant returns `true` and drives the native camera channel; the `stub` returns `false`.

Expose it through a Riverpod provider — `repScanActionsProvider`, mirroring
`catalogLinkActionsProvider` — so a widget test can override it and assert **both** renderings from
one `flutter test` run.

> **Check the mobile half honestly before you build it.** There is no QR scanner package in
> `pubspec.yaml`, and the camera is a bespoke native `MethodChannel`, not the `camera` plugin. So
> "scan on mobile" is itself unbuilt work: either extend the native channel with a decode, or add a
> package with a written justification. **If neither is in scope, set `kCanScanQrCode = false` on
> all three variants** and ship manual entry everywhere — genuinely identical behaviour, and note J
> then carries the scanning experience on both targets. That is the recommended path.

### 3. Dish capture on web — note H

**The capture flow cannot run in a browser.** The camera is a native `MethodChannel`
(`lib/platform/permissions_service.dart` routes every Android permission to it), there are no
sensors, and the Makefile already records web as "no share sheet, no camera".

**Do not build a broken path, and do not invent a new one.** The catalog surface already answered
this exact question — matrix note A: `_SourceSelector` offers **3D model** ("from a finished
capture") and **Photo** ("image only — no AR"), and never opens a camera on *either* target.

The rep add-dish screen reuses that selector plus one mobile-only source:

| Source | Mobile | Web |
|---|---|---|
| Capture this dish now | ✅ | ⛔ hidden |
| From a finished capture | ✅ | ✅ |
| Photo (image-only) | ✅ | ✅ |

So a rep on a laptop can activate a code, author the whole menu as image-only dishes, and publish.
They cannot shoot dishes. **State that plainly in the screen's file comment and in the matrix** —
it is the one genuine functional difference between the targets, and pretending otherwise is worse
than naming it.

### 4. The CSV export seam — note I

Stage 2's `GET /admin/qr-batches/:id/export` returns `text/csv` behind a Bearer token. That is
exactly row 9's situation: the bytes need an authenticated fetch, so the browser cannot be handed a
plain link.

**Generalise `qr_delivery_{io,web,stub}.dart` rather than copying it.** It already does the right
thing — Blob, object URL, click, and `revokeObjectURL` immediately after, because leaking one per
press keeps every file the user ever saved resident for the life of the tab. Widen
`QrDownloadFile` to a `DownloadFile` carrying bytes, a filename and a MIME type, and let both the
QR and the CSV ride it.

**Backend check, already satisfied:** `Content-Disposition` is in the CORS `exposedHeaders`
allowlist (`src/app.ts:46`). A browser cannot *read* a response header unless it is exposed — without
it the download is named `export` with no extension. Stage 2 gets this for free; assert it in
`cors.test.ts` rather than assuming.

> Only build a Flutter UI for this if an admin actually wants one. Batch minting is plausibly a
> curl-and-Postman job. **Decide before building** — an unused admin screen is worse than none.

### 5. Deep link into activation — note J

This is the step that makes both targets feel the same, and it removes most of the need for step 2.

The rep's **OS camera** scans the standee and opens `{PUBLIC_RESOLVER_BASE_URL}/r/{code}`. For an
`UNASSIGNED` code that renders stage 3's "not live yet" page. **Add one link to that page:**

> *Are you a Mirage rep? **Activate this code.***

pointing at the rep surface with the code prefilled. Then:

- **Web:** the link is `{WEB_APP_BASE_URL}/rep/activate?code={code}`. It just works — same browser,
  same session. This is the *better* experience of the two.
- **Mobile:** needs a real App Link / Universal Link to open the app.

**⚠ That mobile half does not work today, and the manifest is misleading about it.**
`AndroidManifest.xml:107-114` sets `android:autoVerify="true"` on an intent-filter whose scheme is
the **custom** `recapture://app` — `autoVerify` does nothing for a non-https scheme. iOS has
`CFBundleURLSchemes: recapture` (`Info.plist:65-77`) and **no** `applinks:` associated domain. So
an `https` link cannot open the app on either platform.

Two honest options:

| Option | Cost | Result |
|---|---|---|
| **A — ship web-only deep linking now** | ~0 | Web reps get one-tap activation; mobile reps type the code. Both work |
| **B — real App Links + Universal Links** | assetlinks.json + apple-app-site-association on the resolver host, associated-domains entitlement, manifest change | One-tap on all three targets |

**Recommend A now, B when the resolver host is settled** — B needs files served from
`PUBLIC_RESOLVER_BASE_URL`, which stage 3 is the first thing to define. Do not half-build B; a
`autoVerify` that silently fails is exactly the state the manifest is in already.

Also add the prefill route on both targets regardless of option:
`/rep/activate?code=` must accept the param and skip straight to the preflight.

### 6. Confirm the URL strategy before relying on a query param — note F extended

Matrix note F records that deep-link **refresh** needs a hosting rewrite this repo does not contain
— no `firebase.json`, `_redirects` or `vercel.json` anywhere in the tree. `/rep/*` inherits that
open item exactly as `/catalog/*` has it.

**One thing to verify rather than assume:** `usePathUrlStrategy()` / `setUrlStrategy()` appear
**nowhere** in `lib/` or `web/`, so the build may be on the hash strategy (`/#/rep/activate`), in
which case note F's rewrite is not needed and the deep link in step 5 must be written with the
hash. Note F is worded as though the path strategy is in use. **Check which it actually is, build
the step-5 link to match, and correct whichever document is wrong.**

Whichever it is, put it in the matrix — a link that works in dev and 404s in prod is the exact
failure this stage exists to prevent.

### 7. Session lifetime — note E applies to reps too, and matters more

`flutter_secure_storage` on web is **browser storage, not a keychain**: readable by any script that
achieves XSS on the origin, with no OS-level protection. The matrix already records this and calls
the web build "a *convenience authoring surface*" whose "session lifetime deserves to stay short".

A `SALES_REP` session is a higher-value target than an owner session: it can activate codes and
create restaurant accounts across **many** tenants, where an owner token reaches exactly one
catalog.

**Do not add a web-only auth mechanism** — that is a much larger change than this stage. Do:

- confirm the existing refresh-token rotation applies unchanged to rep sessions;
- keep stage 4's `/rep` activation rate window in place, which bounds what a stolen web session can
  do per hour;
- record the reasoning in the matrix row, so shortening rep session TTL is a known available lever
  rather than a later discovery.

---

## Tests to write

**Extend** `test/catalog/web_parity_test.dart` (structural half):

- The rep tree contains no `dart:io` import.
- The rep tree contains no `kIsWeb` deciding layout.
- `rep_scan_{io,web,stub}.dart` all exist and export the same symbols — an incomplete
  conditional-import seam is a web-build-only failure with no test symptom otherwise.

**New** `test/rep/rep_web_parity_test.dart` (behavioural half) — override the provider, assert both
platforms from one run:

- `kCanScanQrCode: true` → the Scan button renders **and** manual entry renders.
- `kCanScanQrCode: false` → manual entry renders and the Scan button is **absent from the tree**,
  not merely disabled. Assert `findsNothing`, not a disabled state.
- Both mixes reach a working activation through manual entry — the parity claim itself.

**New** `test/rep/rep_add_dish_source_test.dart`:

- With capture available, three sources render.
- Without it, exactly two render and the capture source is **absent**.
- Both mixes can create a dish.

**Extend** the download seam test:

- A CSV `DownloadFile` and a QR `DownloadFile` both round-trip through the shared seam with the
  right filename and MIME type.

**Backend** — extend `recapture-api/tests/cors.test.ts`:

- `Content-Disposition` is exposed on the batch-export response. (The matrix lists
  `cors.test.ts` coverage for catalog routes as an open item; closing it for the new routes while
  you are here is cheap.)

---

## Done when

- [ ] The matrix has rows 15–24 and notes G–J, in the existing file.
- [ ] The structural guard walks the rep tree, mutation-checked both ways.
- [ ] `rep_scan_{io,web,stub}.dart` exist; the flag is read through a provider, never `kIsWeb`.
- [ ] Every unavailable affordance is **absent from the widget tree**, asserted with `findsNothing`.
- [ ] The add-dish source list is 3 on mobile / 2 on web, and both can create a dish.
- [ ] CSV and QR share one download seam — no second copy of the Blob dance.
- [ ] The URL strategy is confirmed and written down; step 5's link matches it.
- [ ] Deep link option A or B is chosen and recorded; if A, the mobile gap is written in the matrix
      rather than left implied.
- [ ] `flutter analyze && flutter test` — green.
- [ ] `make verify` — analyze, test, **web build**, APK build all pass.
- [ ] **Manual, side by side:** run the same activation on a phone and in Chrome. Every step behaves
      identically except capture and scan, and each of those two is a clean absence, not an error.

---

## What "same page" honestly means

Worth stating plainly, because it is the question this stage answers:

| | App | Web |
|---|---|---|
| Sign in as a rep | ✅ | ✅ |
| Scan a standee with the OS camera | ✅ | ✅ (note J) |
| Enter or paste a code | ✅ | ✅ |
| Activate a restaurant | ✅ | ✅ |
| See delegated catalogs | ✅ | ✅ |
| Add a dish from a finished capture | ✅ | ✅ |
| Add an image-only dish | ✅ | ✅ |
| Watch generating → ready | ✅ | ✅ |
| Download the standee QR | ✅ | ✅ |
| Publish | ✅ | ✅ |
| **Photograph a dish** | ✅ | ⛔ **no camera in a browser** |
| **In-app QR scanner** | ⚠️ unbuilt | ⛔ (note J covers it) |

**One row is genuinely different**, and it is a platform limit rather than a decision: a browser has
no camera pipeline, no sensors and no permission channels. Everything else is the same code on both
targets, gated by capability flags a test can drive.

The honest framing for a rep: **the phone is the field tool, the browser is the desk tool.** Both
can activate a restaurant and run its menu; only the phone can shoot the dishes.

---

## Rollback

Client-only and additive. Revert the seam files and the rep tree's entry in the structural guard.
The matrix rows should stay even if the code goes — they record what was learned about the targets,
which outlives any one implementation.
