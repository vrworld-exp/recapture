// lib/platform/exposure_policy.dart
//
// Three-band classification policy for the mean-luminance exposure score (average
// of the Y/luma plane, 0–255, from the exposure-check task): DARK (<darkBelow),
// OK (darkBelow..brightAbove inclusive), BRIGHT (>brightAbove). Mirrors the native
// ExposureThresholdPolicy so the capture flow / UI can classify a mean from any
// source (e.g. a captured frame's sidecar) consistently with the live stream.
//
// Both DARK and BRIGHT are WARN states — the spec rejects/gates nothing on
// exposure; the concrete UI hint ("too dark"/"too bright") is wired by the capture
// flow, not here.
import 'package:flutter/foundation.dart';

/// The actionable band a mean luminance falls into.
enum ExposureBand {
  /// Too dark — warn ("too dark").
  dark,

  /// Well exposed — good.
  ok,

  /// Too bright — warn ("too bright").
  bright,

  /// The mean could not be determined (e.g. an empty/NaN frame). Never silently OK.
  unknown;

  /// Parses the native wire form (`dark`/`ok`/`bright`/`unknown`); null if unknown
  /// shape. Note `'unknown'` maps to [ExposureBand.unknown] (an explicit value),
  /// whereas an unrecognized string returns `null`.
  static ExposureBand? fromWire(Object? wire) => switch (wire) {
        'dark' => ExposureBand.dark,
        'ok' => ExposureBand.ok,
        'bright' => ExposureBand.bright,
        'unknown' => ExposureBand.unknown,
        _ => null,
      };

  /// Whether this band should surface a warning (DARK or BRIGHT). OK and UNKNOWN
  /// do not warn.
  bool get isWarning => this == ExposureBand.dark || this == ExposureBand.bright;
}

/// Configurable, validated thresholds + the classification.
@immutable
class ExposureThresholdPolicy {
  const ExposureThresholdPolicy._(this.darkBelow, this.brightAbove);

  /// Builds a validated policy. A non-finite input falls back to the per-field
  /// default; a non-separated pair (`darkBelow >= brightAbove`) falls back to BOTH
  /// defaults. Unlike the blur policy, equality is NOT allowed — DARK and BRIGHT
  /// must be strictly separated by a non-empty OK band.
  factory ExposureThresholdPolicy({double? darkBelow, double? brightAbove}) {
    final d = (darkBelow != null && darkBelow.isFinite)
        ? darkBelow
        : defaultDarkBelow;
    final b = (brightAbove != null && brightAbove.isFinite)
        ? brightAbove
        : defaultBrightAbove;
    return d < b
        ? ExposureThresholdPolicy._(d, b)
        : const ExposureThresholdPolicy._(defaultDarkBelow, defaultBrightAbove);
  }

  static const double defaultDarkBelow = 40;
  static const double defaultBrightAbove = 220;

  static const ExposureThresholdPolicy defaults =
      ExposureThresholdPolicy._(defaultDarkBelow, defaultBrightAbove);

  final double darkBelow;
  final double brightAbove;

  /// `mean < darkBelow` → dark; `mean > brightAbove` → bright; else ok (so exactly
  /// [darkBelow] and [brightAbove] are ok). A non-finite mean → [ExposureBand.unknown]
  /// — never silently ok.
  ExposureBand classify(double mean) {
    if (!mean.isFinite) return ExposureBand.unknown;
    if (mean < darkBelow) return ExposureBand.dark;
    if (mean > brightAbove) return ExposureBand.bright;
    return ExposureBand.ok;
  }
}
