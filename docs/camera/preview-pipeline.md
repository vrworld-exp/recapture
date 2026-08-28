# CameraX → Flutter preview pipeline

Live back-camera **preview** for the capture screen. Scope is preview only — no
`ImageAnalysis`, still/video capture, or sensor fusion here (separate tasks).

## Architecture decision: A — external Texture (chosen)

CameraX renders into an `android.view.Surface` obtained from Flutter's
`TextureRegistry.SurfaceProducer`; Flutter draws `Texture(textureId)`. Chosen over
the PlatformView/`PreviewView` alternative for native compositing of the existing
capture overlays (tilt meter, coverage ring, instruction banner already stacked
over the feed) and no PlatformView cost. Trade-off: rotation is handled manually.

There is **no composition mode** to document — that caveat applies only to the
PlatformView alternative (B), which was not built.

**Fill mode:** FILL_CENTER (crop) — the Flutter wrapper scales the texture with
`BoxFit.cover`. Confirmed against the full-bleed capture UI.

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../camera/CameraPreviewManager.kt` | Owns CameraX `Preview` + a private `LifecycleRegistry`; `start`/`stop`/`dispose` drive bind/unbind. |
| Native host | `android/.../MainActivity.kt` | Registers the channel; disposes the manager on a real `finish()`. |
| Dart | `lib/platform/camera/camera_preview_controller.dart` | Channel driver + observable `CameraPreviewState`; degrades errors gracefully. |
| Dart | `lib/platform/camera/camera_preview_view.dart` | `Texture` + rotation + `BoxFit.cover`; error/placeholder surfaces. |
| Screen | `lib/presentation/screens/capture/capture_screen.dart` | Hosts the preview; stops on background, restarts on resume, disposes on leave. |

## Channel `com.mayasabhaxr.recapture/camera_preview`

Dart → native:

- `start` → `{ textureId, previewWidth, previewHeight, rotationDegrees }`
  (resolved once the first `SurfaceRequest` is fulfilled). Error codes:
  `PERMISSION_DENIED`, `NO_BACK_CAMERA`, `BIND_FAILED`, `CANCELLED`.
- `stop` → release the camera, keep the manager reusable.
- `dispose` → full teardown, release the camera + producer.

Native → Dart (same channel):

- `onPreviewChanged` `{ previewWidth, previewHeight, rotationDegrees }` on rotation/size change.
- `onError` `{ code, message }` for failures after `start` resolved.

## Lifecycle correctness (the hard part)

- The manager owns a private `LifecycleOwner`, decoupled from the Activity, so
  `bindToLifecycle` is authoritative to `start`/`stop`/`dispose` and survives the
  Activity config-change recreation suppressed by `android:configChanges`.
- **Background:** `SurfaceProducer.onSurfaceCleanup` → lifecycle to `CREATED` +
  `unbindAll` (never render to a dead surface). **Resume:**
  `onSurfaceAvailable` → re-bind, CameraX issues a fresh `SurfaceRequest`.
- **Dispose-while-binding race:** a `bindGeneration` counter invalidates a stale
  `ProcessCameraProvider` future; teardown wins.
- **Permission:** assumed granted by the P2 gate; never requested here. A missing
  grant fails `start` with `PERMISSION_DENIED` (defensive, no crash).
- **Threading:** `bindToLifecycle` on the main thread (CameraX requirement);
  surface requests / transformation callbacks on a dedicated single-thread executor.

## Focus / exposure lock controls

Layered onto the **same bound session** via Camera2 interop
(`Camera2CameraControl` / `Camera2CameraInfo`) — no rebind/recreate. The preview
manager hands the bound `Camera` to `CameraControlsManager.updateCamera(...)` on
every bind/unbind through `CameraPreviewManager.onCameraChanged`.

Native: `android/.../camera/CameraControlsManager.kt`. Dart:
`lib/platform/camera/camera_controls.dart` (`CameraControls` — shares the channel
but never sets a method-call handler, so it doesn't clobber the preview
controller's native-push handler).

Controls (all four chosen, capability-gated):

- **AE lock** — `CONTROL_AE_LOCK` (gated on `CONTROL_AE_LOCK_AVAILABLE`).
- **AWB lock** — `CONTROL_AWB_LOCK` (gated on `CONTROL_AWB_LOCK_AVAILABLE`).
- **AF hold** — non-auto-cancel center `FocusMeteringAction`
  (`startFocusAndMetering(...).disableAutoCancel()`); unlock →
  `cancelFocusAndMetering()`. No manual-distance hardware required.
- **Manual focus distance** — `AF_MODE=OFF` + `LENS_FOCUS_DISTANCE` (diopters,
  clamped to `[0, minFocusDistance]`); gated on
  `LENS_INFO_MINIMUM_FOCUS_DISTANCE > 0` **and** `AF_MODE_OFF` available.

Channel methods (same `camera_preview` channel):
`getCameraControlCapabilities()` → `{ aeLock, awbLock, manualFocus, focusDistanceRange? }`,
`setExposureLock(locked)`, `setAutoWhiteBalanceLock(locked)`,
`setFocusLocked(locked)`, `setManualFocusDistance(distance)`, `unlockAll()`.
Errors: `NO_CAMERA` (no bound session), `UNSUPPORTED` (control gated off) — the
Dart wrapper turns both into a graceful no-op (`false` / `none`).

**Precedence:** AF hold and manual distance conflict — `setFocusLocked(true)`
drops any manual distance; `setManualFocusDistance` is the manual path;
`setFocusLocked(false)` and `unlockAll()` clear both → auto AF.

**Apply model:** every mutation rebuilds `CaptureRequestOptions` from tracked
state and does `clearCaptureRequestOptions()` then `setCaptureRequestOptions(...)`
so a removed key (e.g. `AF_MODE` when leaving manual focus) is dropped.
`setCaptureRequestOptions` dispatches to CameraX's executor (off main); the
future's completion resolves the result on the main thread.

**Rebind decision: reset to auto.** A new (or null) `Camera` from
`updateCamera(...)` drops all tracked locks, so a session always starts in full
auto and the capture flow re-locks as needed. (Switch `updateCamera` to re-apply
remembered state if session-long lock-through-background is later required.)

## Still capture — single / burst / auto (CameraX ImageCapture)

Adds still-capture to the **same** session. `CameraCaptureManager` owns an
`ImageCapture` use case which `CameraPreviewManager` binds **alongside Preview**
(`captureUseCase`, bound in the same `bindToLifecycle` — Preview + ImageCapture is
a CameraX-guaranteed pair, no fallback needed). The preview manager's
`onCameraChanged` drives `onCameraBound`/`onCameraUnbound`.

Native: `android/.../camera/CameraCaptureManager.kt`. Dart:
`lib/platform/method_channels.dart` (`CaptureChannel`) +
`lib/platform/event_channels.dart` (`CaptureEvents` stream of `CaptureEvent`).

Channels:
- MethodChannel `com.mayasabhaxr.recapture/capture` — `captureSingle()` →
  `{id, path, timestampNs}`; `startBurst(count, intervalMs?)` /
  `startAutoCapture(intervalMs?)` → `{sessionId}` ack; `stopAutoCapture()`.
- EventChannel `com.mayasabhaxr.recapture/captureEvents` — discriminated by
  `type`: `frame {id,path,timestampNs,index,total?}`,
  `completed {count,sessionId}`, `error {index?,message}`.

Decisions (confirmed):
- **Capture mode:** `CAPTURE_MODE_MINIMIZE_LATENCY`, JPEG via the in-memory
  `ImageProxy` path — read `imageInfo.timestamp` (ns, sensor timestamp), write the
  JPEG bytes, close the proxy immediately (bounded memory). RAW not implemented.
- **AF/AE lock:** `startBurst`/`startAutoCapture` call
  `CameraControlsManager.lockForCapture()` (AE lock if supported + AF hold) and
  **stay locked** — the caller releases via `unlockAll`. A background rebind
  resets to auto (existing behavior).

Behavior:
- **Back-pressure:** captures are serialized — the next `takePicture` is scheduled
  only after the prior completes (on a single-thread `ScheduledExecutorService`),
  so device drain gates cadence. `intervalMs` is a *minimum* spacing; if the
  device is slower, it fires immediately and the slower effective cadence shows in
  the per-frame `timestampNs`. No unbounded queue, no silent drops.
- **Concurrency:** one operation at a time; a concurrent request → `BUSY`.
- **Per-frame failure:** report-and-continue — the failed index emits an `error`
  event and the index advances (gap marked).
- **Lifecycle:** `stopAutoCapture`/dispose/background (`onCameraUnbound`) halt the
  loop and finalize (`completed`); an in-flight frame after stop is dropped
  (cancellation). `isRunning(op)` gates every step against
  disposed/unbound/superseded so a torn-down session is never captured to.
- **Output:** app-scoped `getExternalFilesDir(null)/captures/<sessionId>/` (no
  storage permission), files `cap_<ts>_<index>_<timestampNs>.jpg` — timestamp on
  disk in the name and in the event.
- **Threading:** MethodChannel returns immediately (single returns its frame);
  capture/write run on the capture executor; events post to the EventSink on main.

Out of scope (hooks only / separate tasks): the sensor/motion auto-trigger
criterion, pose association, and reconstruction.

## Manual verification (device required)

See the task's Testing Instructions: live preview, dispose-releases-camera (another
consumer can bind), background/foreground resume, rotation without stretch, rapid
enter/leave with no leak, camera-unavailable graceful error, hot-restart re-bind,
and start-without-jank. The Dart wrapper is covered by
`test/capture/camera_preview_controller_test.dart`.
