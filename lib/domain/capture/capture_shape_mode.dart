// lib/domain/capture/capture_shape_mode.dart
//
// Pure Dart — NO Flutter/Riverpod imports. The capture SHAPE MODE: how much a
// session captures. It is ORTHOGONAL to the two other capture axes and must not
// be confused with either:
//
//   • CaptureMode {guided, manual}  — the auto-capture DRIVE (POST /projects
//     `mode`). Says whether the shutter fires automatically, not how much is shot.
//   • CaptureFlowVariant {withBottom, withoutBottom} — a FULL-only question about
//     the OBJECT (is the bottom capturable?). Meshy ignores it entirely.
//
//   full  → the 48-shot photogrammetry flow (Eye/Top[/Bottom] rings, A/B/C).
//   meshy → a short capture tuned for the Meshy AI model selector: ONE Eye ring
//           of 6 shots taken ~60° apart in yaw, with camera tilt anywhere in
//           [90,180) (eye-level → top-down) so the single ring covers both the
//           eye view and the top. Manual shutter, all 6 required, variant-less.
//           The server auto-selects the best 4 of the 6 to send to Meshy.
//
// The wire ids ('full'/'meshy') MATCH the backend captureMode enum
// (recapture-api/src/models/types/captureVariants.ts). Never rename an existing id.
enum CaptureShapeMode {
  full,
  meshy;

  /// Canonical wire/persistence id — used on POST /jobs, in the manifest, and in
  /// the per-project Hive store. Never rename.
  String get id => switch (this) {
        CaptureShapeMode.full => 'full',
        CaptureShapeMode.meshy => 'meshy',
      };

  bool get isMeshy => this == CaptureShapeMode.meshy;

  /// Tolerant parse of a wire/persisted id. Unknown or null → [full] (every
  /// project that predates Meshy mode). Never throws — matches the repo's
  /// defensive-parse convention (see [CaptureFlowVariant.fromId]).
  static CaptureShapeMode fromId(String? id) =>
      id == 'meshy' ? CaptureShapeMode.meshy : CaptureShapeMode.full;
}
