# Prompt: make Full Capture and Maya (Meshy) Capture work on Flutter Web

## Why this exists

Both capture modes are non-functional in the web build. This is **not a bug** — it
is a missing platform implementation. Every input the capture flow consumes comes
from a native MethodChannel/EventChannel, and web has **zero** implementations of
any of them:

| Channel constant (`lib/utils/constants.dart`) | Wrapper | What breaks on web |
|---|---|---|
| `channelCameraPreview` | `lib/platform/camera/camera_preview_controller.dart:97`, `camera_controls.dart:69` | no preview surface, no texture id |
| `channelCapture` | `lib/platform/method_channels.dart:159` | shutter / burst / auto-capture throw |
| `channelCaptureEvents` | `lib/platform/event_channels.dart:129` | no per-frame results |
| `channelImuRotation` / `channelImuOrientation` | `lib/platform/imu_rotation_channel.dart:86,191` | no yaw / camera-tilt → no band, no ring progress |
| `channelStability` | `lib/platform/stability_channel.dart:117` | never "stable" |
| `channelBlur` | `lib/platform/blur_channel.dart:95` | no sharpness score |
| `channelExposure` | `lib/platform/exposure_channel.dart:92` | no mean luminance |
| `channelCaptureStorage` | `lib/platform/capture_storage.dart:147` | no frame paths, no accounting |
| `channelPermissions` | `lib/platform/permissions/android_permission_channel.dart:36` | see below |

Four concrete, separately-caused failures follow from that:

1. **Black preview.** `CameraPreview.build` (`lib/platform/camera/camera_preview_view.dart:47`)
   branches on `defaultTargetPlatform`, which on web reports the **host OS**, not
   "web". A phone browser therefore takes the Android `Texture(textureId)` path or
   the iOS `UiKitView` path — both dead. `hasTexture` is never true, so the widget
   shows `_DefaultPlaceholder` forever.
2. **Permissions throw before capture starts.** `PermissionsService._backendFor`
   (`lib/platform/permissions_service.dart:171`) contains an explicit
   `throw StateError('Permissions are not supported on web')`.
3. **Full mode's auto-capture never fires.** `AutoCaptureController.evaluate`
   delegates to the pure `shouldCapture`, whose inputs (in-band tilt, stability)
   come only from the IMU/stability channels. No stream → the predicate is
   permanently false → the loop is silent even with a live preview.
4. **Maya (Meshy) mode is blocked *correctly*.** `CaptureMode.meshy.usesHardTiltGate`
   is `true`, which disables the fail-open in `CaptureReadiness`
   (`lib/domain/entities/capture_readiness.dart`). With no tilt stream the Meshy
   shutter is *designed* to stay blocked ("adjust tilt"). **Do not weaken this
   rule to make web pass.** The fix is to give web a real tilt source, never to
   turn the hard gate off.

Downstream, the captured photo is a **file path** (`CapturedPhotoRecord.framePath`,
`lib/application/capture/ledger/captured_photo_record.dart`), rendered via
`Image.file(File(...))` (`lib/presentation/widgets/thumbnail_strip.dart:137`), and
the entire upload chain imports `dart:io`
(`capture_bundle_packer.dart`, `capture_manifest_assembler.dart`,
`multipart_upload_api.dart`, `domain/upload/file_checksum.dart`, `upload_flow.dart`).
None of that compiles or runs on web.

## Scope and priority (read before planning)

**Ship Maya/Meshy web first, then Full.** Meshy is 6 photos, manual shutter, one
ring, no auto loop — it is genuinely achievable at parity in a browser. Full is 48
photos with an auto-capture loop and photogrammetry-grade quality expectations;
browser `getUserMedia` gives no exposure lock, no focus lock, no RAW, lower
resolution, and no background upload, so **web Full capture will be a degraded
tier, not parity**. Build it, but state the degradation in the UI rather than
pretending otherwise.

**Non-goals.** Do not change any mode/variant shape numbers (`full` = 48,
`meshy` = one ring of 6), do not weaken `usesHardTiltGate`, `oneShotPerSegment`,
or `CaptureReadiness`'s fail-open rules, and do not alter native Android/iOS
behaviour anywhere. Every change is additive behind a web branch. `AGENTS.md`
wins on any convention conflict.

## Architectural rule for the whole change

**Do not litter `kIsWeb` through the application and presentation layers.**
Introduce a *port* per native capability, with an `_io` (existing channel) and a
`_web` (browser) implementation selected by conditional import — the pattern
already proven in this repo by `lib/application/projects/model_export_service.dart:21`
and `preview_download_service.dart:23`:

```dart
import 'x_stub.dart'
    if (dart.library.io) 'x_io.dart'
    if (dart.library.js_interop) 'x_web.dart';
```

The application layer (`lib/application/capture/**`) and every pure domain type
(`lib/domain/**`) must end this change **unmodified**. If a change there feels
necessary, the port boundary is in the wrong place.

Ports to introduce under `lib/platform/capture_ports/`:

| Port | Native impl | Web impl |
|---|---|---|
| `CameraPreviewPort` | existing `channelCameraPreview` | `getUserMedia` → `<video>` in `HtmlElementView` |
| `StillCapturePort` | existing `channelCapture` | draw video frame to `OffscreenCanvas` → JPEG bytes |
| `OrientationPort` (yaw + camera tilt, degrees, 0–180 tilt scale) | `channelImuRotation` / `channelImuOrientation` | `DeviceOrientationEvent` |
| `StabilityPort` | `channelStability` | `DeviceMotionEvent` accelerometer variance |
| `FrameQualityPort` (blur + luminance) | `channelBlur` / `channelExposure` | Web Worker over `ImageData` |
| `CaptureStoragePort` | `channelCaptureStorage` | IndexedDB blob store |
| `CapturePermissionsPort` | `channelPermissions` / `permission_handler` | Permissions API + gesture-gated prompts |

## Web implementation requirements, per port

### 1. Camera preview
Register a platform view (`HtmlElementView`) hosting a `<video autoplay muted
playsinline>` fed by `getUserMedia({ video: { facingMode: 'environment',
width: { ideal: 1920 } } })`. `playsinline` and `muted` are load-bearing on iOS
Safari — without them the video goes fullscreen or refuses to autoplay.

Then fix `camera_preview_view.dart:47` so the **first** branch is web, before the
`defaultTargetPlatform` checks. Web must never reach the `Texture` or `UiKitView`
path. Map browser errors onto the existing `CameraPreviewStatus.error` +
`errorCode`/`errorMessage` surface so no new UI states are invented:
`NotAllowedError` → permission denied, `NotFoundError` → no camera,
`NotReadableError` → device busy.

### 2. Still capture
On shutter, draw the current `<video>` frame to a canvas at the video's intrinsic
resolution and encode JPEG at the quality already declared by
`CaptureResolutionPolicy.jpegQuality` (default 90). Honour
`CaptureAspectRatio` by cropping the draw rect — **preview FOV and capture FOV
must match**, which the native contract already requires.

Return the existing `CapturedFrame` shape. Since web has no filesystem, make
`path` an opaque handle (e.g. `idb://{jobId}/{level}/{frameId}.jpg`) that resolves
through `CaptureStoragePort`, and supply a real `timestampNs` from
`performance.now()` converted to nanoseconds so the sensor-alignment fields stay
meaningful.

### 3. Orientation → yaw + camera tilt
Subscribe to `deviceorientation` and convert `alpha/beta/gamma` into the app's
existing conventions: yaw in degrees, and **camera tilt on the documented 0–180
scale (0 = at the sky, 90 = horizon/eye level, 180 = at the ground)** per
`lib/domain/capture/camera_tilt.dart`. Getting this mapping wrong silently breaks
band gating, ring progress, and the Meshy `[60,180)` window — write the conversion
as a pure function with unit tests before wiring it to anything.

Handle screen rotation: `beta`/`gamma` are relative to the device's natural
orientation, so compose with `screen.orientation.angle`.

Apply the **same smoothing** the native `SmoothedOrientation` applies, so
identical physical motion produces comparable stability and band behaviour across
platforms.

**iOS Safari requires `DeviceOrientationEvent.requestPermission()` from a user
gesture.** Wire this into `CapturePermissionsPort` as a real permission with a
real prompt, not an implicit subscription. If it is denied:
- `full` → fail-open as today (`sensorSupported: false`), surface the existing
  "guidance unavailable" note;
- `meshy` → the hard gate blocks, which is correct. Show an explicit, honest
  screen: motion access is required for Maya Capture in this browser, with a
  retry that re-triggers the gesture-gated request. **Do not silently downgrade
  Meshy to an ungated shutter.**

### 4. Stability
Derive from `devicemotion` acceleration variance over a short rolling window,
calibrated to emit `stable` under roughly the same physical steadiness as native.
Emit through the existing stability state type — no new enum.

### 5. Frame quality (blur / exposure)
Compute variance-of-Laplacian (blur) and mean luminance (0–255) from canvas
`ImageData` in a **Web Worker**, on a downscaled copy (e.g. long edge 512) — the
scores are relative and the full-res pass would jank the preview. Return them in
the units the existing `CaptureVerdict` / quality-decision code already expects,
so `AutoCaptureController`'s `QualityFn` is unchanged. Verify the thresholds in
`CaptureQualityDecision` still discriminate on downscaled web scores; if they do
not, add a **web-specific threshold set in config**, never a code fork of the
decision logic.

### 6. Storage
IndexedDB store keyed `{projectId}/{jobId}/{level}/{frameId}`, holding the JPEG
`Blob` plus its metadata. Implement the full `CaptureStoragePort` surface the
native channel exposes — usage (`frameCount`/`byteCount`), incomplete-job listing,
and scoped deletion (level/job/project), including the **active-job delete guard**
(`StorageDeleteResult.code == 'active_job'`), because the project-deletion cleanup
hook depends on it.

Never hold 48 full-resolution JPEGs in Dart heap. Write each frame to IndexedDB
immediately on capture and keep only handles in memory. Use
`navigator.storage.estimate()` for the free-space check that native performs, and
surface a real error before capture starts if the quota cannot fit the expected
count.

Thumbnails: `thumbnail_strip.dart` and the review grids must resolve bytes through
the port instead of `Image.file(File(path))`. Give `CaptureThumbnail`/the review
item a bytes-or-path resolution exactly like `project_photo_picker.dart:211-212`
already does (`kIsWeb ? bytes : path`) — reuse that precedent, do not invent a
second convention. Revoke object URLs on dispose.

### 7. Permissions
Implement the web branch of `PermissionsService` and delete the `kIsWeb`
`StateError` at `permissions_service.dart:171`. Camera status via the Permissions
API where supported, falling back to attempting `getUserMedia`; motion via the iOS
`requestPermission()` path above; photos → permission-free on web. Preserve the
existing `AppPermissionType` → status semantics so the permissions screen needs no
new states.

### 8. Upload
Provide a bytes-based upload path so nothing in the web build reaches `dart:io`.
Split `capture_bundle_packer.dart`, `capture_manifest_assembler.dart`,
`multipart_upload_api.dart`, and `domain/upload/file_checksum.dart` behind
`_io`/`_web` implementations. MD5 checksums must stay **streaming** over `Blob`
slices — do not read a whole bundle into memory to hash it. The manifest content
and the multipart protocol must be byte-identical to native; the server must not
be able to tell which platform produced a job.

Background upload does not exist on web: `upload_background_session.dart:128` and
`upload_foreground_service.dart:34` already return unsupported for `kIsWeb`, which
is correct. Add a `beforeunload` warning while an upload is in flight, and make
the uploading screen say plainly that the tab must stay open — the resume path on
web is "re-open and retry", not "it continued in the background".

## Hard requirements (non-negotiable)

- HTTPS only. `getUserMedia` and the motion sensors are secure-context APIs.
  Document this in the README web section; it is the single most likely cause of a
  "works locally, dead on staging" report.
- Every mode/variant count is unchanged: `full × with_bottom` = 16/16/16,
  `full × without_bottom` = 24/24, `meshy` = one ring of 6 for both variants.
- `full` fails open on missing sensors; `meshy` hard-gates. Unchanged on web.
- `oneShotPerSegment` still holds for Meshy on web.
- The upload manifest and `POST /jobs` payload are unchanged. **No backend changes
  in this task.**
- Analytics keep emitting; extend the platform-string helper (currently
  `defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android'`, repeated at
  ~30 call sites) to yield `'web'`. Do this once in a shared helper and replace
  the call sites — do not add a third inline ternary.

## Preflight gate (add this; it is the difference between "broken" and "honest")

Before the capture screen mounts on web, run a capability probe and route to a
clear unsupported screen when a **required** capability is missing, naming the
missing one:

- `getUserMedia` + at least one environment-facing camera — required by both modes.
- `DeviceOrientationEvent` (granted) — required by `meshy`; optional for `full`.
- IndexedDB writable, and estimated quota ≥ expected bundle size.
- Secure context.

A user who cannot capture must learn that in one screen at the start, not after
shooting 30 photos that cannot upload.

## Tests

Follow the existing layout under `test/` (`capture/`, `imu/`, `stability/`,
`blur/`, `exposure/`, `storage/`, `upload/`, `platform/`).

1. **Pure conversion tests, no browser needed** — the orientation mapping
   (`alpha/beta/gamma` + screen angle → yaw + 0–180 tilt) against a table of known
   device poses, including the Meshy `[60,180)` boundaries (60 inclusive, 180
   exclusive) and both landscape orientations.
2. **Port-contract tests** run against *both* implementations via fakes, asserting
   identical observable behaviour: capture returns a frame with a non-empty handle
   and non-zero `timestampNs`; storage usage accounting; the `active_job` delete
   guard; readiness composition per mode.
3. **Readiness regression** — assert on web-shaped inputs that `full` with
   `sensorSupported: false` still allows capture, and `meshy` with
   `sensorSupported: false` still blocks. These two must be explicit tests; they
   are the rules most likely to be "fixed" by mistake.
4. **Photo-count tests unchanged** — `test/capture/full_capture_photo_counts_test.dart`
   and the Meshy count tests must pass untouched.
5. **Widget test** — `CameraPreview` on a web-flagged build renders neither
   `Texture` nor `UiKitView`.
6. `flutter analyze` clean, and **`flutter build web` must compile** — today a
   `dart:io` import in the upload chain is enough to fail it.

## Acceptance criteria

Verified on Chrome Android and Safari iOS, over HTTPS, on a real phone:

1. **Maya Capture:** preview is live; the shutter is blocked outside `[60,180)`
   and unblocked inside it; 6 shots fill 6 distinct wedges; a 7th into a filled
   wedge is refused; the job uploads and reaches the same post-upload state as
   native. Note `kMeshyAutoGenerateEnabled` (`lib/utils/feature_flags.dart`)
   defaults to **false**, so the default build offers the manual "Generate 3D
   model" button rather than generating automatically — verify web matches
   whichever way the flag is set, do not assume auto-generation.
2. **Full Capture:** preview is live; the auto-capture loop fires on tilt +
   stability + segment conditions; all 48 land across the correct rings for the
   chosen variant; ring progress, the review grid, and retake all work from
   IndexedDB-backed thumbnails; the bundle uploads with a byte-identical manifest.
3. Denying camera, or denying motion on iOS, produces the specific named error —
   never a black screen, never a silently dead shutter.
4. Android and iOS native builds are behaviourally unchanged; the full existing
   test suite passes.

## Deliverable

Report honestly at the end which capabilities are **at parity**, which are
**degraded** (name the degradation: resolution, no exposure/focus lock, no
background upload), and which are **unsupported per browser**. If web Full capture
cannot meet photogrammetry quality, say so in the report and add a visible notice
in the web UI rather than shipping a mode that quietly produces unusable models.
