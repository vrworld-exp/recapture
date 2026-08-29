# ReCapture — Projects Hub

Guided photogrammetry capture app by **MayasabhaXR Technologies**. A Flutter
client plus a Node/TypeScript backend, in one repo.

> **Conventions & architecture decisions live in [AGENTS.md](./AGENTS.md)** — read
> it before contributing. This README is just setup and run steps.

---

## Layout

| Path | What |
|---|---|
| `lib/` | Flutter client (layered clean architecture: `domain` → `data` → `application` → `presentation`) |
| `recapture-api/` | Node + TypeScript backend (Express + Mongoose) |
| `test/` | Flutter tests (hermetic; Hive temp-dir helpers) |
| `docker-compose.yml` | Local MongoDB for backend dev |
| `.github/workflows/ci.yml` | CI: backend typecheck+lint, Flutter analyze+test, Android deploy |

## Prerequisites

- **Node ≥ 20** and npm (backend)
- **Flutter 3.22.x** / **Dart `>=3.4.0 <4.0.0`** (client)
- **Docker** (optional, for a local MongoDB) — or a MongoDB Atlas URI

---

## Backend (`recapture-api/`)

```bash
cd recapture-api
npm install
cp .env.example .env          # then fill in secrets (see below)

# Local MongoDB (from repo root, optional):
#   docker compose up -d
# and set MONGODB_URI=mongodb://localhost:27017/recapture in .env

npm run dev                   # tsx watch, hot-reload
```

Verify it's up: `GET http://localhost:3000/health`.

**Config** is validated at boot by `src/config/env.ts` and **fails fast** if a
required var is missing. Required (no default): `MONGODB_URI`, `JWT_SECRET` (≥32
chars), and the AWS/S3/CloudFront vars. All OTP/token/rate-limit tunables have
safe defaults — see `.env.example` and `env.ts`. **Never commit secrets.**

**Scripts:**

| Command | Does |
|---|---|
| `npm run dev` | Run with hot reload (`tsx watch`) |
| `npm run type-check` | `tsc --noEmit` (strict — must be clean) |
| `npm run lint` | ESLint |
| `npm run build` | `tsc` + `tsc-alias` → `dist/` |
| `npm start` | Run the built server |

Deploys to **Render** (`render.yaml`).

---

## Client (repo root)

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # riverpod/hive/freezed codegen
flutter run                                                 # dev flavor
```

**Checks:**

| Command | Does |
|---|---|
| `flutter analyze` | Static analysis (lints) |
| `flutter test` | Unit/widget tests |

The client reads config from `.env` via `flutter_dotenv` (declared as an asset in
`pubspec.yaml`). Auth tokens are stored in the OS Keychain/Keystore via
`flutter_secure_storage`; non-secret cache/state lives in Hive.

---

## Web (capture in a browser)

Both capture modes run in a browser. Everything the capture flow consumes goes
through a port in `lib/platform/capture_ports/`, with an `_io` (native
MethodChannel/EventChannel) and a `_web` (browser API) implementation selected by
conditional import — so the application and domain layers are identical on every
platform.

```bash
flutter run -d chrome        # dev; localhost counts as a secure context
flutter build web            # release bundle in build/web
```

### HTTPS is mandatory

`getUserMedia`, `DeviceOrientationEvent` and `DeviceMotionEvent` are all
**secure-context** APIs. Served over plain HTTP (anything other than
`localhost`), `navigator.mediaDevices` is not merely blocked — it is *undefined*,
and the motion events never fire.

This is the single most likely cause of a "works locally, dead on staging"
report: `flutter run -d chrome` serves from `localhost`, which is a secure
context, so every browser API works; a staging deploy over `http://` fails
completely. The capture preflight names this case first
(`CaptureCapability.secureContext`) precisely so the symptom is not mistaken for
a broken camera.

The page must also not be embedded in an iframe without
`allow="camera; accelerometer; gyroscope; magnetometer"`.

### What is at parity, what is degraded, what is unsupported

| Capability | Web status |
|---|---|
| Live preview | **Parity** — `getUserMedia` → `<video>` in an `HtmlElementView` |
| Tilt / yaw guidance | **Parity** — `DeviceOrientationEvent` converted to the same body→world quaternion and smoothed by a Dart port of the native filter |
| Stability gate | **Parity** — the native dwell gate ported to Dart, fed from `devicemotion` |
| Blur / exposure scores | **Parity of scale** — the native metrics ported and normalized to the same 640px width, so one threshold set serves both. Runs on the main thread at ~8 Hz rather than in a Web Worker (see the note in `frame_quality_port_web.dart`) |
| Photo counts, band rules, one-shot-per-wedge | **Parity** — unchanged, shared code |
| Manifest + multipart upload protocol | **Parity** — same layout, same deterministic names, same streaming MD5 |
| Capture resolution | **Degraded** — whatever the browser negotiates (typically 1920×1080), not the sensor's full still resolution |
| Exposure / focus / white-balance lock | **Unsupported** — no browser API exists; `CameraControls` reports no capabilities and its setters return false |
| RAW capture | **Unsupported** |
| EXIF + JSON sidecar metadata | **Unsupported** — the manifest carries `metadata: null` for web photos (an explicitly allowed value; the backend can see the gap) |
| Background upload | **Unsupported** — the tab must stay open. The uploading screen says so, and a `beforeunload` handler arms the browser's own "Leave site?" confirmation. Recovery is "re-open and retry" |
| Local storage of captures | **Different, not worse** — frames go straight into IndexedDB under `{projectId}/{jobId}/{level}/`, keyed the same way the native capture tree is foldered |

**Full Capture on web is a degraded tier, not parity.** Without exposure or focus
lock and at a lower negotiated resolution, a 48-photo browser capture will
generally reconstruct less well than the same capture taken in the app. The
pre-capture screen says this in the UI; do not treat browser Full Capture as
equivalent input for photogrammetry. Maya (Meshy) Capture — 6 manual shots — is
genuinely achievable at parity.

### iOS Safari: motion access is a real permission

Safari 13+ gates the orientation/motion events behind
`DeviceOrientationEvent.requestPermission()`, which must be called **from a user
gesture** and cannot be re-prompted once denied. The app models this as a real
permission (`AppPermissionType.motion` → the browser backend), so:

- **Full Capture** fails open, exactly as on a sensor-less phone — capture works,
  guidance does not.
- **Maya Capture** hard-gates, by design: its `[60, 180)` tilt window is the
  mode's guarantee, so a browser with no tilt stream cannot take a Maya shot.
  The preflight screen says so and offers a retry that re-triggers the
  gesture-gated request. This is deliberately **not** downgraded to an ungated
  shutter.

### Preflight

Before the capture screen mounts, `CapturePreflightGate` probes: secure context,
`getUserMedia` + at least one camera, granted motion (required for `meshy`,
optional for `full`), a writable IndexedDB, and enough remaining quota for the
expected bundle. A missing required capability is named on one screen up front,
rather than discovered after 30 photos that cannot upload.

---

## CI

`.github/workflows/ci.yml` runs on push to `main`/`dev` and PRs to `main`:

- **backend-typecheck-lint** — `tsc --noEmit` + ESLint on `recapture-api/`
- **flutter-analyze** / **flutter-test** — client checks
- **build-android** — signed AAB → Play internal track (push to `main` only)
- **build-ios** — disabled stub (activation checklist in `fastlane/Fastfile`)

---

## More

- **Conventions, stack decisions, API envelope, data/PII/analytics patterns:** [AGENTS.md](./AGENTS.md)
- **Agent context alias:** [CLAUDE.md](./CLAUDE.md) → points to AGENTS.md
