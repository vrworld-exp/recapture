# ReCapture — Project Overview

**ReCapture** (by MayasabhaXR Technologies) is a guided photogrammetry capture
app plus its backend. Users are walked through a structured capture flow (multi-
level rings of photos around an object), the bundle is uploaded to S3, and a
backend worker processes it into a 3D asset.

This repo holds **two codebases** in one tree:

- **Flutter/Dart client** — at the repo root (`lib/`, plus native `android/` &
  `ios/`).
- **Node/TypeScript backend** — in `recapture-api/`.

> The single source of truth for conventions is [AGENTS.md](../AGENTS.md). This
> file is a higher-level map of *where things live* and *what tech is used*.

---

## Tech Stack at a Glance

| Area | Technology |
|------|-----------|
| **Client framework** | Flutter 3.22.x / Dart `>=3.4.0 <4.0.0` |
| **Client state** | Riverpod (`flutter_riverpod` + `riverpod_annotation`) |
| **Client navigation** | `go_router` |
| **Client HTTP** | Dio (interceptor pipeline hosts the auth-refresh seam) |
| **Client local storage** | Hive (non-secret cache/state) |
| **Client secure storage** | `flutter_secure_storage` (auth tokens → OS Keychain/Keystore) |
| **Client config** | `flutter_dotenv` (`.env`, `.env.dev/.staging/.prod`) |
| **Codegen** | `build_runner` (riverpod / hive / freezed / json_serializable) |
| **Android native** | Kotlin (CameraX, Camera2 interop, sensors, storage) |
| **iOS native** | Swift (AVFoundation camera, CoreMotion, URLSession background upload) |
| **Backend framework** | Express + TypeScript (`strict` on) |
| **Backend datastore** | MongoDB (Atlas) via Mongoose ODM |
| **Backend validation** | Zod |
| **Backend object storage** | AWS S3 (`@aws-sdk/client-s3`, presigned multipart) |
| **Backend auth** | JWT (`jsonwebtoken` / `express-jwt`), HMAC OTP |
| **Cache / rate-limit** | **No Redis** — DB-backed sliding windows |
| **Hosting** | Backend → Render (region `singapore`); Client → Play Store via Fastlane |
| **Runtime pinning** | Node ≥ 20 |

---

## Frontend (Flutter client)

Located at the **repo root**. Layered clean architecture:
**domain → data → application → presentation**.

```
lib/
├── main.dart          ← entry point
├── domain/            ← entities, value types (pure Dart, no Flutter/IO)
├── data/              ← local/ (Hive), remote/ (Dio), repositories/ (own all HTTP)
├── application/       ← Riverpod notifiers (pure state; never touch network)
├── presentation/      ← screens/ + widgets/
├── app/               ← routes/, theme/, bootstrap
├── native/            ← Dart side of platform MethodChannels (camera/sensors/upload)
├── platform/          ← platform abstractions/seams
├── dev/               ← dev tools (health probe, S3 smoke test)
└── utils/             ← cross-cutting helpers (e.g. analytics)
```

Key foundations:
- **Tokens** live in secure storage, **not** Hive.
- **Hive boxes:** `active_session`, `projects_cache`, `config_cache`,
  `offline_queue` (names centralized in `data/local/box_names.dart`).
- **Dio** interceptor pipeline hosts the token-refresh seam.
- **Connectivity** is a mockable abstraction so offline behavior is testable.
- Client tests live under `test/` (auth, config, offline, projects, storage) —
  run with `flutter test`.

### Android native code

Path: **`android/app/src/main/kotlin/com/mayasabhaxr/recapture/`** (Kotlin)

- `camera/` — CameraX preview → Flutter external Texture, capture, controls,
  resolution policy, blur/exposure analysis, capture metadata/EXIF.
- `sensors/` — IMU rotation stream, orientation filter (quaternion low-pass),
  stability gate/score.
- `permissions/` — custom MethodChannel permission manager (replaces
  `permission_handler` on the native side).
- `storage/` — capture storage backbone, job manifest, segment layout.
- `upload/` — foreground service + resume worker for background uploads.
- `MainActivity.kt` — channel wiring.

Manifest & resources: `android/app/src/main/AndroidManifest.xml`, `res/`.

### iOS native code

Path: **`ios/Runner/`** (Swift — *ports; several unverified on device*)

- `CameraPreviewManager` / `CameraPreviewPlatformView` / `CameraCaptureManager`
  / `CameraControlsManager` — AVFoundation camera pipeline.
- `BlurAnalysisManager` / `BlurMetric` / `BlurThresholdPolicy` — quality checks.
- `ImuOrientationStreamHandler` / `SensorStreamHandler` / `OrientationFilter` —
  CoreMotion sensor streams.
- `CaptureStorage` / `CaptureStorageChannelHandler` / `StorageSegments` /
  `JobManifest` — on-device capture storage.
- `BackgroundUploadManager` / `UploadEventStreamHandler` — URLSession
  `.background` uploads.
- `AppDelegate.swift` / `SceneDelegate.swift` — app lifecycle.

---

## Backend (`recapture-api/`)

Express + TypeScript. Layering: **routes → services → models** (thin routers;
business logic in services; services avoid Express types).

```
recapture-api/src/
├── config/      ← env.ts (Zod-validated, fail-fast), db.ts, s3.ts
├── routes/      ← thin Express routers
├── services/    ← business logic
├── models/      ← Mongoose schemas + interfaces
├── middleware/  ← auth, requireRole, validate, errorHandler, notFound, requestLogger
├── validation/  ← Zod schemas per route group
├── providers/   ← SMS/email seams (stubbed)
├── worker/      ← job queue worker (npm run worker)
├── utils/       ← otp, tokens, rateLimit, cursor, analytics, asyncHandler
└── types/       ← express.d.ts (req.user augmentation)
```

Imports use the `@/*` path alias → `src/*`. Dev via `tsx watch`; build is
`tsc` + `tsc-alias` (the alias rewrite is required).

### Routes
- `auth.ts` — send-OTP / verify-OTP / refresh / me (HMAC OTP, token rotation +
  family-revoke).
- `projects.ts` — list / create / get / rename / delete (cursor pagination,
  soft-delete + confirmName).
- `jobs.ts` — create-job, upload-urls (presigned multipart), finalize-job.
- `admin.ts` — staff-only (`MODEL_ARTIST`+) read-only live-projects list/detail
  + presigned-GET export manifest.
- `remoteConfig.ts` — public client config (ETag/304).
- `health.ts` — warmup ping (wakes Render).

### Services
`otpService`, `verifyOtpService`, `refreshTokenService`, `projectsService`,
`adminProjectsService`, `jobsService`, `manifestValidationService`,
`remoteConfigService`, `s3MultipartService`, `s3ObjectStore`.

### Models (Mongoose)
`User`, `Project`, `Job`, `OtpCode`, `RefreshToken`, `RateWindow`,
`VerifyThrottle`, `ClientConfig`.

### Key backend conventions
- **One API envelope:** success `{ status: "success", ... }`; error
  `{ status: "error", code, message }`.
- **Roles:** `USER | MODEL_ARTIST | ADMIN`, inclusive-upward; role is a fresh
  DB read per request (not a JWT claim). Granted only via
  `scripts/set-user-role.ts`.
- **Storage:** capture bundles go to S3 (`us-east-1` buckets) via presigned
  multipart; keys are job-rooted; finalize verifies object count → flips job to
  QUEUED → worker picks it up.
- **Rate limiting:** DB-backed sliding windows (no Redis).
- **PII:** never log raw phone/email/OTP/tokens; hash identifiers via
  `hashIdentifier`.

---

## Data & Processing Flow (high level)

1. **Auth** — phone OTP → JWT access + refresh (rotation, family-revoke).
2. **Project** — user creates a project (soft-delete supported).
3. **Capture** — guided multi-level ring capture on device (native camera +
   sensors), quality gating (blur/exposure/stability), bundle packed locally
   with a manifest + per-file MD5.
4. **Upload** — create-job → presigned multipart upload-urls → finalize-job
   (S3 count check enqueues the job).
5. **Processing** — backend worker polls the job queue and runs the pipeline
   stages (PROCESSING → TEXTURING → OPTIMIZING); pipeline compute is a seam/stub.
6. **Preview / delivery** — staff export manifest (`/admin`) and per-project
   photo preview gallery with share-sheet download.

---

## Common Commands

**Client** (repo root):
```
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # codegen
flutter analyze
flutter test
flutter run                                                 # dev flavor
```

**Backend** (`cd recapture-api`):
```
npm install
npm run dev          # tsx watch (needs .env — copy .env.example)
npm run worker       # job queue worker
npm run type-check   # tsc --noEmit (must be clean)
npm run lint
npm run build        # tsc + tsc-alias → dist/
npm start
npm test             # vitest
```

**Local Mongo** (backend dev): `docker compose up -d`.

---

## Hosting & CI

- **Backend** → Render (`recapture-api/render.yaml`, region `singapore`);
  secrets via Render env vars (`sync: false`).
- **Client** → Play Store via Fastlane (Android internal track, CI on push to
  `main`). **iOS CI is a disabled stub.**
- **CI** (`.github/workflows/ci.yml`) — backend (tsc + lint) + Flutter
  (analyze + test) + deploy.

---

*See [AGENTS.md](../AGENTS.md) for the full conventions (envelope, roles,
config/secrets, data-layer patterns, PII/logging rules, analytics seam, testing).*
