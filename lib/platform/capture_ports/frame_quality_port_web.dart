// lib/platform/capture_ports/frame_quality_port_web.dart
//
// WEB implementation of [FrameQualityPort]: one throttled analysis pass over the
// live `<video>`, producing a blur result and an exposure result per frame from
// a SINGLE downscaled grayscale buffer — the same one-downscale-two-metrics
// arrangement the native analyzer uses, which is what keeps the two results'
// `timestampNs` / `frameIndex` genuinely paired.
//
// Two deliberate choices, both about cost:
//
//  1. **640px width, not "512 long edge".** Variance-of-Laplacian scales with
//     resolution, so normalizing to any other size would have shifted every
//     score off the scale `BlurThresholdPolicy` (100 / 40 / 220) and
//     `CaptureQualityDecision` were tuned at, forcing a web-specific threshold
//     set. Using the native normalization width removes that problem instead of
//     managing it. The browser does the downscale itself inside `drawImage`,
//     which is GPU-accelerated, so the Dart pass only ever walks the small
//     buffer.
//
//  2. **Analysis runs on the Dart main thread at [analysisInterval] (~8 Hz),
//     not in a Web Worker.** This is a knowing deviation from the original
//     plan. Flutter web has no isolates, so a real worker would mean a SECOND,
//     hand-written JavaScript implementation of the Laplacian and the mean —
//     two copies of the one thing that must agree with native, drifting
//     independently. The pass here is a single walk of a ~640xN 8-bit buffer at
//     8 Hz. If profiling on a low-end phone shows it costing frames, the right
//     fix is to lower [analysisInterval] or the normalization width behind a
//     config value, NOT to fork the metric.
import 'dart:async';

import 'package:flutter/services.dart';

import '../blur_policy.dart';
import '../exposure_policy.dart';
import 'frame_quality_math.dart';
import 'frame_quality_port.dart';
import 'web_camera_source.dart';

/// Selected by the conditional import in lib/platform/blur_channel.dart and
/// lib/platform/exposure_channel.dart on a web build. Both resolve to the SAME
/// analyzer so blur and exposure describe the same frame.
FrameQualityPort createFrameQualityPort({
  EventChannel? blurChannel,
  EventChannel? exposureChannel,
}) =>
    WebFrameQualityPort.instance;

/// Canvas-backed [FrameQualityPort].
class WebFrameQualityPort implements FrameQualityPort {
  WebFrameQualityPort._();

  static final WebFrameQualityPort instance = WebFrameQualityPort._();

  /// ~8 Hz. Fast enough that the "hold steady / too dark" hints track what the
  /// user is doing, slow enough that the pass is a rounding error per frame.
  static const Duration analysisInterval = Duration(milliseconds: 125);

  final _blur = StreamController<BlurResult>.broadcast();
  final _exposure = StreamController<ExposureResult>.broadcast();

  Timer? _timer;
  int _frameIndex = 0;
  BlurThresholdPolicy _blurPolicy = BlurThresholdPolicy.defaults;
  ExposureThresholdPolicy _exposurePolicy = ExposureThresholdPolicy.defaults;
  double _sharpCutoff = BlurMetric.defaultThreshold;

  @override
  Stream<BlurResult> blur({
    double? blurThreshold,
    double? rejectBelow,
    double? acceptAbove,
  }) {
    if (blurThreshold != null && blurThreshold >= 0) {
      _sharpCutoff = blurThreshold;
    }
    _blurPolicy = BlurThresholdPolicy(
      rejectBelow: rejectBelow ?? BlurThresholdPolicy.defaultRejectBelow,
      acceptAbove: acceptAbove ?? BlurThresholdPolicy.defaultAcceptAbove,
    );
    _ensureRunning();
    return _blur.stream;
  }

  @override
  Stream<ExposureResult> exposure({double? darkBelow, double? brightAbove}) {
    _exposurePolicy = ExposureThresholdPolicy(
      darkBelow: darkBelow ?? ExposureThresholdPolicy.defaultDarkBelow,
      brightAbove: brightAbove ?? ExposureThresholdPolicy.defaultBrightAbove,
    );
    _ensureRunning();
    return _exposure.stream;
  }

  void _ensureRunning() {
    _timer ??= Timer.periodic(analysisInterval, (_) => _analyze());
  }

  void _analyze() {
    // Nothing is listening (both HUD overlays gone) — stop burning frames.
    if (!_blur.hasListener && !_exposure.hasListener) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final source = WebCameraSource.instance;
    if (!source.isRunning) return;

    // One draw at the normalization width; the browser scales, we only walk the
    // small result. No aspect crop here: the metric is a whole-frame statistic
    // and native likewise analyses the full analysis frame.
    final canvas = source.drawFrame(targetWidth: BlurMetric.defaultTargetWidth);
    if (canvas == null) return;
    final rgba = source.readPixels(canvas);
    if (rgba == null) return;

    final gray = lumaFromRgba(rgba, canvas.width, canvas.height);
    final variance = BlurMetric.laplacianVariance(gray);
    final mean = ExposureMetric.meanLuminance(gray);
    final timestampNs = source.lastDrawTimestampNs;
    final index = _frameIndex++;

    if (_blur.hasListener && !_blur.isClosed) {
      _blur.add(BlurResult(
        sharpnessScore: variance,
        sharp: variance >= _sharpCutoff,
        band: _blurPolicy.classify(variance),
        rejectBelow: _blurPolicy.rejectBelow,
        acceptAbove: _blurPolicy.acceptAbove,
        width: gray.width,
        height: gray.height,
        timestampNs: timestampNs,
        frameIndex: index,
      ));
    }
    if (_exposure.hasListener && !_exposure.isClosed) {
      _exposure.add(ExposureResult(
        meanLuminance: mean,
        band: _exposurePolicy.classify(mean),
        darkBelow: _exposurePolicy.darkBelow,
        brightAbove: _exposurePolicy.brightAbove,
        width: gray.width,
        height: gray.height,
        timestampNs: timestampNs,
        frameIndex: index,
      ));
    }
  }
}
