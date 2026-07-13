// lib/dev/dev_probe/dev_probe_models.dart
//
// Value/state types for the Dev Tools probe (see dev_probe_service.dart for
// the module header). Dev-only tooling — not part of the app's domain layer.
import 'dart:convert';

/// Outcome of one GET /health round trip — raw display material, never parsed
/// as the standard envelope (health is deliberately a non-envelope endpoint).
class HealthCheckResult {
  const HealthCheckResult({
    required this.ok,
    required this.latencyMs,
    required this.baseUrl,
    this.statusCode,
    this.body,
    this.errorType,
    this.errorMessage,
  });

  /// True when an HTTP response came back at all (any status code).
  final bool ok;
  final int latencyMs;
  final String baseUrl;
  final int? statusCode;

  /// Pretty-printed raw response body (when a response arrived).
  final String? body;

  /// DioExceptionType name when the backend was unreachable.
  final String? errorType;
  final String? errorMessage;
}

enum ProbeStepState { pending, running, success, failure }

/// One row of the upload smoke pipeline's step list.
class ProbeStep {
  ProbeStep({required this.id, required this.title});

  final String id;

  /// Mutable so the aggregated upload row can carry live "n/49" progress.
  String title;
  ProbeStepState state = ProbeStepState.pending;

  /// Raw response JSON (pretty-printed) on success, or the failure detail
  /// (envelope code/message/validationErrors verbatim) on failure.
  String? detail;
}

/// Mutable run state for one tap of the Upload smoke test. The service owns
/// and mutates it, invoking `onUpdate` after every change so the UI can render
/// live progress.
class UploadSmokeRun {
  UploadSmokeRun({required this.steps, required this.totalFiles});

  final List<ProbeStep> steps;
  final int totalFiles;
  int filesCompleted = 0;
  int totalBytes = 0;
  Duration? elapsed;

  bool get running =>
      elapsed == null && steps.any((s) => s.state == ProbeStepState.running);
  bool get failed => steps.any((s) => s.state == ProbeStepState.failure);
  bool get succeeded =>
      steps.every((s) => s.state == ProbeStepState.success);
}

/// Pretty-prints any JSON-decodable value for the monospace detail blocks.
String prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}
