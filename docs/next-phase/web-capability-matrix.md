# Web capability matrix — the catalog surface

> **What this is.** One row per catalog capability, and what it does on each target. The
> phase ships **APK and Flutter web** from one codebase, so every capability that does not
> exist on both needs a deliberate answer — hidden, substituted, or documented as
> unsupported. A capability that is merely *broken* on one target is a bug, not a row.
>
> **Kept in the repo on purpose.** This file is the artifact F11 produces. It is checked
> against the code by `test/catalog/web_parity_test.dart`, which drives the capability
> flags through their providers — if a gate is removed, that test fails and this table is
> what tells the next person what the gate was for.

## The rule this table exists to enforce

**`kIsWeb` is for capabilities, never for layout.** Layout comes from `BoxConstraints` — a
narrow browser window is a phone layout, not a squeezed desktop one
(`lib/presentation/widgets/model_picker_field.dart:34`). Grepping the catalog surface for
`kIsWeb` returns **only comments explaining why it is not used there**; the real platform
splits are compile-time **conditional imports**, which is the stricter form of the same
idea:

```dart
import 'qr_delivery_stub.dart'
    if (dart.library.io) 'qr_delivery_io.dart'
    if (dart.library.js_interop) 'qr_delivery_web.dart';
```

Two properties fall out of that, and both matter more than the tidiness:

1. **The unsupported path is not compiled in.** `dart:io` cannot reach a web build even by
   accident, so "no `dart:io` on a catalog path" is enforced by the compiler rather than by
   review.
2. **The screen asks rather than tests.** Capability flags (`kCanShareLink`, `kCanOpenLink`)
   are read through a Riverpod provider, so a widget test overrides them to assert *both*
   platforms' rendering without running on either. A `kIsWeb` branch is untestable by
   construction — that is the actual argument against it, not style.

---

## Matrix

| # | Capability | Android / iOS | Web | Mechanism | Seam |
|---|---|---|---|---|---|
| 1 | **Fresh-scan product source** (camera) | n/a | n/a | **Not offered on either.** See note A. | — |
| 2 | **3D product from finished capture** | ✅ | ✅ | Reads existing models by id; no device capability | `add_product_screen.dart` |
| 3 | **Image-only product** | ✅ | ✅ | Bytes end-to-end, one picker with a web path | `product_image_picker.dart` |
| 4 | **Product image upload** (presigned `PUT`) | ✅ | ✅ | Same repo method; needs S3 CORS. See note D. | `catalog_products_repository.dart` |
| 5 | **Background / foreground upload services** | ✅ gated | ⛔ gated off | `!kIsWeb &&` platform check | `upload_background_session.dart:128`, `upload_foreground_service.dart:34` |
| 6 | **3D preview** (`model-viewer`) | ✅ WebView | ✅ DOM | meshopt decoder set in **both** trigger sites. See note C. | `model_render_view.dart`, `web/index.html` |
| 7 | **AR launch** | ✅ where supported | ⛔ desktop / ✅ mobile web | Asked of `model-viewer`'s own `canActivateAR`, never of the platform | `preview_product_card.dart:149` |
| 8 | **AR CTA when AR unavailable** | shown + explained | **hidden** on desktop browser | `showArCtaWhenUnavailable: false` | `preview_product_card.dart` |
| 9 | **QR download / save** | share sheet → Files | `<a download>` of a Blob | Conditional import, one repo method | `catalog_qr_service.dart` |
| 10 | **Share public link** | ✅ share sheet | ⛔ **button hidden** | `kCanShareLink` | `catalog_link_delivery_{io,web}.dart` |
| 11 | **Open public link in new tab** | ⛔ **button hidden** | ✅ `window.open` | `kCanOpenLink`. See note B. | `catalog_link_delivery_{io,web}.dart` |
| 12 | **Copy public link** | ✅ | ✅ | Flutter `Clipboard` handles the secure-context fallback in-engine | `catalog_link_service.dart` |
| 13 | **Auth token storage** | Keychain / Keystore | **browser storage, not a keychain** | See note E. | `auth_storage.dart` |
| 14 | **Deep link to `/catalog/...` + refresh** | n/a | ⚠️ **needs a hosting rewrite** | See note F. | `app_router.dart` |

Legend: ✅ works · ⛔ deliberately absent, affordance **hidden** not disabled · ⚠️ needs
configuration outside the Flutter build.

---

## Notes

### A. There is no camera source in the catalog surface at all

The batch prompt asks for the fresh-scan source to be *hidden on web*. It is hidden on
**both**, because it was never offered: `_SourceSelector` presents exactly two options —
**3D model** ("from a finished capture") and **Photo** ("image only — no AR"). The 3D
option picks an **already-finished** capture by id and never opens a camera, so it works
unchanged in a browser.

That is not an oversight to correct. The backend accepts exactly two product shapes and
each requires its own asset, so a third "capture something now" source would have to run
the whole capture pipeline inside the add-product flow. Capture lives on the projects
surface and is gated there; the catalog consumes its output. **Nothing to gate here** —
the requirement is met by the shape of the feature, and this note exists so the next person
does not go looking for a missing `kIsWeb`.

### B. "Open link" is hidden on mobile, and that is the same rule working in reverse

The interesting half of row 11 is the *mobile* column. Opening an external browser needs
`url_launcher`, a new package, which the brief forbids without justification — and the
share sheet already reaches every app that can open a URL. So the button is **hidden on
mobile**, not on web.

This is why the flags are `canShare` / `canOpen` rather than `isWeb`: the capability matrix
is not "mobile has more", it is genuinely mixed. A `kIsWeb` branch would have encoded the
wrong idea and would have to be rewritten the day a desktop target lands.

### C. The meshopt decoder has two trigger sites and both must be set

`web/index.html` and `_lifecycleJs` in `model_render_view.dart`. Fixing one ships the other
platform broken — an optimized GLB simply fails to load, which on the catalog preview means
one product card shows its error body while the rest of the page looks fine. That is a
hard failure to attribute after the fact, which is why
`test/projects/meshopt_decoder_test.dart` guards both sites rather than either.

### D. CORS has two independent halves

- **The API allow-list** (`recapture-api/src/app.ts`): explicit `CORS_ALLOWED_ORIGINS`,
  `credentials: false` (auth rides the `Authorization` header, never a cookie, so no origin
  gets an ambient-authority call). `exposedHeaders: ['Content-Disposition', 'ETag']` — a
  browser cannot *read* a response header unless it is exposed, so without this the QR
  endpoint works but the download is named `qr` with no extension and the ETag cache never
  hits.
- **The S3 bucket CORS rule**, which is infrastructure and not in this repo. The presigned
  `PUT` for product images is issued by the API but executed **by the browser**, so the
  bucket must allow the origin, the `PUT` method, and the `Content-Type` header the client
  sends.

A browser-blocked upload fails in a way the client cannot distinguish from a network error
at the Dio level — see the open item below.

### E. `flutter_secure_storage` on web is not a keychain

On Android it is AES-GCM with RSA-OAEP key wrapping; on iOS the Keychain. **On web it is
browser storage**, subject to the origin's storage being cleared, readable by any script
that achieves XSS on the origin, and offering no OS-level protection.

This is inherent to the platform, not a defect in the wrapper, and it is not weakened for
the catalog. Recorded here so it is a known property rather than a discovery: the web build
should be treated as a *convenience authoring surface*, and its session lifetime deserves to
stay short.

### F. Deep-link refresh needs hosting configuration this repo does not contain

Flutter web's default URL strategy serves `/catalog/products/abc` as a client-side route.
A **page refresh** on that URL is a real GET to the host, which must rewrite unknown paths
to `index.html` or the user gets a 404 on their own product.

There is **no hosting config in the tree** — no `firebase.json`, `_redirects`, `vercel.json`
or equivalent. Whatever host is chosen needs the rewrite, and the auth redirect must return
the user to the deep link after login rather than dropping them on `/catalog`.

---

## Open items

These are gaps this matrix documents rather than closes. They are listed so they are
tracked, not so they look finished.

| Item | Status | Why it is not closed here |
|---|---|---|
| Hosting rewrite for deep-link refresh (note F) | ⬜ **open** | Needs a hosting target to be chosen; it is deployment config, not app code |
| S3 bucket CORS rule for the presigned `PUT` (note D) | ⬜ **unverified** | Infrastructure, not in this repo — must be checked against the live bucket |
| "Browser blocked the upload" as a distinct message | ⬜ **open** | A CORS rejection reaches Dio as an opaque transport error; telling it apart from offline needs a probe, and guessing would put a wrong sentence on screen |
| `cors.test.ts` coverage for the catalog routes | ⬜ **open** | Backend test; `recapture-api/node_modules` is not installed in this working tree |
| Safari / iOS web clipboard + download | ⬜ **untested** | Needs a real device; `Clipboard` and `<a download>` both differ there |

Closed by this pass:

- ✅ **`make build.web.{dev,staging,prod}` and `make run.web`** — the Makefile had APK and IPA
  targets but no web one, so the target the phase ships was the only one without a command.
  `make verify` now runs the full gate (analyze, test, web build, APK build).
- ✅ **`test/catalog/web_parity_test.dart`** — the gates in rows 10–12 are now driven through
  `catalogLinkActionsProvider` and asserted for all three capability mixes, plus source-level
  guards for the `dart:io` and `kIsWeb` rules. Both structural guards were mutation-checked:
  introducing a `dart:io` import and a `kIsWeb` reference into a catalog file fails them.
- ✅ **`QR_SAVE_FAILED` had no mapped copy.** Row 9's failure path — a dismissed share sheet on
  mobile, a browser that refused the download on web — is a *client* sentinel with no envelope
  behind it, and it was falling through to the generic "Something went wrong." It now has its own
  sentence, and it is listed in the enumerating test's `_alwaysRequired` so it cannot go unmapped
  again. This is the one place where the two platforms' failure modes are genuinely
  indistinguishable from the client, so the copy covers both without guessing.
