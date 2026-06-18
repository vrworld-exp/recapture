# Capture metadata: EXIF + per-frame JSON sidecar

Makes each captured JPEG self-describing for the reconstruction pipeline. Runs as
a **per-frame post-capture step** coordinating with the burst task (precise
timestamp + frame paths), the resolution-policy task (actual resolution), and the
focus/exposure-lock task (capture conditions).

Scope is metadata only — no capture triggering, processing, permission, lifecycle,
or **pose** work (pose is a reserved sidecar slot for the sensor/fusion task).

## EXIF vs sidecar — the defining split

| | EXIF (in the JPEG) | JSON sidecar (`<frame>.json`) |
|--|--------------------|-------------------------------|
| Purpose | Standard interop / human | App + pipeline source of truth |
| Time | `DateTime` wall-clock, ~1s (+ `SubSecTime`) | `captureTimestampNs` — **precise monotonic** sensor-alignment key |
| Content | orientation, make/model, software, datetime, intrinsics | device, actual resolution, intrinsics, capture conditions, pose slot |

**Do not conflate** the EXIF wall-clock datetime with the precise alignment
timestamp. The monotonic `captureTimestampNs` (from the burst task) lives ONLY in
the sidecar; the sensor/pose task later joins on it.

## EXIF written (interop only)

orientation (normalized to 1..8, else NORMAL), `Make`/`Model`, `Software`
(`MayasabhaXR/<appVersion>`), `DateTime`/`DateTimeOriginal`/`DateTimeDigitized` +
`SubSecTime*` (human time), and intrinsics when the device exposes them:
`FocalLength`, `FNumber`, `FocalLengthIn35mmFilm`. Arbitrary app data is **not**
crammed into EXIF — it goes in the sidecar.

## Sidecar shape

```json
{
  "sessionId": "...", "frameId": "...", "frameIndex": 0,
  "captureTimestampNs": 123456789012345,
  "wallClockIso": "2026-06-17T10:00:00.123Z",
  "device": { "manufacturer", "model", "osVersion", "appVersion", "cameraId" },
  "resolution": { "width", "height", "aspectRatio", "jpegQuality", "fellBack" },
  "intrinsics": { "focalLengthMm", "focalLength35mm", "fNumber", "sensorWidthMm", "sensorHeightMm" },
  "capture": { "afLocked", "aeLocked", "awbLocked", "exposureTimeNs": null, "iso": null, "focusDistanceDiopters": null },
  "orientationApplied": "normal",
  "pose": null
}
```

- `intrinsics` fields are **omitted** when the device doesn't expose them (never
  fabricated). `focalLength35mm` is derived (focal × 43.27/sensorDiagonal) only
  when focal length + sensor size are both known.
- `exposureTimeNs`/`iso` are explicit `null` (not observed via a CaptureResult here).
- `pose` is always `null` (reserved).

## Privacy

No GPS/location is written. Any GPS in the source EXIF is **stripped by default**
(the app has no location permission).

## Safety + threading

- **Safe write:** EXIF is written to a temp copy, validated as a real JPEG (SOI
  marker + re-open), then the temp **atomically replaces** the original. A mid-write
  failure cannot corrupt the captured JPEG; the sidecar is still written and the
  failure is reported.
- **Off the cadence:** all EXIF + sidecar I/O runs on `CaptureMetadataWriter`'s own
  single-thread I/O executor — never the main thread, never the capture executor.
  Under a fast burst, jobs drain in order (possibly slightly behind capture) and
  every frame is eventually annotated; failures are reported, not silently dropped.

## Reporting

Each processed frame emits on the capture EventChannel:
`{ type:"metadata", frameId, index, jpegPath, sidecarPath, exifOk, sidecarOk, error? }`
→ Dart `CaptureMetadataEvent` (`lib/platform/event_channels.dart`).

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../camera/CaptureMetadata.kt` | Pure: data classes, sidecar map, dependency-free JSON encoder, EXIF orientation/GPS/rational/35mm/SOI helpers, time formatting. |
| Native | `android/.../camera/CaptureMetadataWriter.kt` | Off-thread executor; safe EXIF write + sidecar; result reporting. |
| Native | `android/.../camera/CameraControlsManager.kt` | `snapshotIntrinsics()` / `snapshotConditions()` from `CameraCharacteristics` + lock state. |
| Native | `android/.../camera/CameraCaptureManager.kt` | Snapshots per frame, enqueues to the writer, forwards results to the EventChannel. |
| Dart | `lib/platform/event_channels.dart` | `CaptureMetadataEvent`. |

## Tests

- `android/.../test/.../camera/CaptureMetadataTest.kt` — JVM unit tests: JSON
  encoding, sidecar shape (precise-ts vs wall-clock, omitted intrinsics, reserved
  pose, explicit-null settings), orientation/GPS/rational/35mm/SOI helpers, time.
- `test/capture/capture_channel_test.dart` — `CaptureMetadataEvent` parsing (incl. error).

On-device acceptance (read-back of persisted tags, GPS-strip from a seeded source,
forced-write-failure leaving a valid JPEG, off-main-thread profiling) is verified
manually per the task's testing steps.
