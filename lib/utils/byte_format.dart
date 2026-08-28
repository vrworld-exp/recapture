// lib/utils/byte_format.dart
//
// The SINGLE shared byte→MB formatter (no ad-hoc division scattered across
// widgets). Fixed 1-decimal precision; guarded so partial/zero/negative inputs
// never produce NaN / Infinity / negative output.
import 'dart:math' as math;

/// Bytes per megabyte (MiB — binary, matching typical "MB" UI display).
const int kBytesPerMb = 1024 * 1024;

/// Megabytes (double) for [bytes]. Negative/zero → 0.0. Never non-finite.
double bytesToMb(int bytes) => bytes <= 0 ? 0.0 : bytes / kBytesPerMb;

/// Megabytes formatted to one decimal (e.g. "42.5"). Negative/zero → "0.0".
String formatMb(int bytes) => bytesToMb(bytes).toStringAsFixed(1);

/// "uploaded / total MB" with consistent precision — e.g. "42.5 / 110.2 MB".
/// [uploaded] is clamped to `[0, total]` so it never renders above the total.
String formatMbProgress(int uploadedBytes, int totalBytes) {
  final total = totalBytes < 0 ? 0 : totalBytes;
  final uploaded = math.max(0, math.min(uploadedBytes, total));
  return '${formatMb(uploaded)} / ${formatMb(total)} MB';
}
